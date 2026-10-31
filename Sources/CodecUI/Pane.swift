import AppKit
import SwiftTerm
import CodecCore

/// What a pane needs from the window that holds it.
@MainActor
protocol PaneHost: AnyObject {
    /// Whether the user is looking at this pane: app active, window key, tab selected, pane focused.
    func isInFront(_ pane: Pane) -> Bool
    func split(_ pane: Pane, axis: SplitAxis)
    /// The user asked to close the pane; the host may confirm first.
    func requestClose(_ pane: Pane)
    /// The pane's shell is gone and the pane should be removed now.
    func paneDidFinish(_ pane: Pane)
}

/// One shell in one pane: owns the process, the terminal view and the pane's `Session`.
@MainActor
final class Pane: LocalProcessTerminalViewDelegate {
    let session = Session()
    let view: PaneView
    var terminal: CodecTerminalView { view.terminal }
    weak var host: (any PaneHost)?

    private let environment: AppEnvironment
    private var preferences: Preferences { environment.preferences }
    private let activity = ActivityCounter()
    private var timer: Timer?
    private var ticks = 0
    private(set) var fontSize: CGFloat
    /// The Settings font size `fontSize` was last derived from; ⌘+/⌘− zoom stays relative to it.
    private var baseFontSize: CGFloat
    private var oscObservation: TerminalOscObservation?
    private(set) var isShutDown = false

    init(directory: String?, environment: AppEnvironment) {
        self.environment = environment
        fontSize = CGFloat(environment.preferences.fontSize)
        baseFontSize = fontSize
        view = PaneView(session: session, preferences: environment.preferences)
        view.onRestart = { [weak self] in self?.restart() }
        view.onDismiss = { [weak self] in
            guard let self else { return }
            self.host?.paneDidFinish(self)
        }

        terminal.processDelegate = self
        terminal.bellStyle = .sound
        terminal.onBell = { [weak self] in self?.handleBell() }
        terminal.contextMenuProvider = { [weak self] _ in self?.contextMenu() }
        let counter = activity
        terminal.setProcessOutputHandler { counter.tick() }
        oscObservation = terminal.observeOscEvents { [weak self] event in
            guard event.code == IntegrationEvent.oscCode,
                  let parsed = IntegrationEvent(payload: String(decoding: event.payload, as: UTF8.self)) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(parsed) }
            }
        }

        applyPreferences()
        session.directory = directory ?? NSHomeDirectory()
        start()
    }

    // MARK: - Process

    /// The environment the shell starts with.
    func shellEnvironment(shell: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["TERM_SESSION_ID", "ITERM_SESSION_ID", "ITERM_PROFILE", "TMUX", "TMUX_PANE",
                    "__CFBundleIdentifier", "CODEC_ORIG_ZDOTDIR", "_CODEC_HOOKED", "CODEC_SHELL_INTEGRATION"] {
            env.removeValue(forKey: key)
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Codec"
        env["TERM_PROGRAM_VERSION"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        env["CODEC_PANE_ID"] = session.id.uuidString
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        if preferences.shellIntegration, let integration = environment.shellIntegration {
            env = integration.environment(env, forShell: shell)
        }
        return env
    }

    private func start() {
        let shell = preferences.resolvedShell()
        let name = (shell as NSString).lastPathComponent
        session.processName = name
        session.exitStatus = nil
        session.running = nil
        terminal.startProcess(
            executable: shell,
            args: [],
            environment: shellEnvironment(shell: shell).map { "\($0.key)=\($0.value)" },
            execName: "-" + name,
            currentDirectory: session.directory.isEmpty ? NSHomeDirectory() : session.directory)
        refreshGitBranch()
        startTimer()
    }

    func restart() {
        guard !isShutDown else { return }
        if session.exitStatus == nil {
            // Still running: ending the shell brings us back here through processTerminated.
            terminal.terminate()
            return
        }
        view.setExitBannerVisible(false)
        terminal.feed(text: "\r\n")
        start()
        view.window?.makeFirstResponder(terminal)
    }

    /// Ends the shell for good: the pane is going away.
    func shutDown() {
        guard !isShutDown else { return }
        isShutDown = true
        timer?.invalidate()
        oscObservation?.cancel()
        if terminal.process.running { terminal.terminate() }
        environment.notifier.clear(id: session.id.uuidString)
    }

    /// A program other than the shell is in the foreground.
    var hasRunningJob: Bool {
        guard session.exitStatus == nil, terminal.process.running,
              let pid = ProcessInspector.foregroundProcess(ptyFD: terminal.process.childfd) else { return false }
        return pid != terminal.process.shellPid
    }

    // MARK: - Polling

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        if activity.drain() > 0, !session.unseenOutput, host?.isInFront(self) == false {
            session.unseenOutput = true
        }
        ticks += 1
        if ticks % 4 == 0 { pollProcess() }
    }

    private func pollProcess() {
        guard terminal.process.running else { return }
        if let foreground = ProcessInspector.foregroundProcess(ptyFD: terminal.process.childfd),
           let name = ProcessInspector.name(of: foreground), name != session.processName {
            session.processName = name
        }
        // Without integration, follow the shell's working directory by asking the kernel.
        if !session.integrated,
           let directory = ProcessInspector.workingDirectory(of: terminal.process.shellPid),
           directory != session.directory {
            session.directory = directory
            refreshGitBranch()
        }
    }

    private func refreshGitBranch() {
        let branch = GitInfo.branch(at: URL(fileURLWithPath: session.directory))
        if branch != session.gitBranch { session.gitBranch = branch }
    }

    // MARK: - Shell integration

    func handle(_ event: IntegrationEvent) {
        let command = session.running?.command ?? ""
        session.apply(event)
        guard case .commandFinished(let exitCode, let duration) = event else { return }
        refreshGitBranch()
        let reaction = preferences.attentionPolicy.reactionToFinishedCommand(
            duration: duration, paneInFront: host?.isInFront(self) ?? false)
        let program = CommandNames.program(of: command)
        perform(reaction,
                title: exitCode == 0 ? "“\(program)” finished" : "“\(program)” failed",
                body: "\(exitCode == 0 ? "Completed" : "Exit status \(exitCode)") after \(Formatting.duration(duration)) · \(session.abbreviatedDirectory)")
    }

    func jumpToCommand(previous: Bool) {
        let row = previous ? terminal.previousSemanticPromptRow() : terminal.nextSemanticPromptRow()
        if let row {
            terminal.scrollTo(row: row)
        } else if !previous {
            terminal.scrollTo(row: Int.max)
        }
    }

    // MARK: - Bell & attention

    func handleBell() {
        let reaction = preferences.attentionPolicy.reactionToBell(paneInFront: host?.isInFront(self) ?? false)
        perform(reaction, title: "Bell in \(session.title)", body: session.abbreviatedDirectory)
    }

    private func perform(_ reaction: AttentionPolicy.Reaction, title: String, body: String) {
        if reaction.indicator { showBellIndicator() }
        if reaction.markForAttention {
            // Already waiting for the user: one notification and one ring is enough.
            guard !session.needsAttention else { return }
            session.needsAttention = true
            environment.coordinator?.attentionDidChange()
            if reaction.notify {
                environment.notifier.post(id: session.id.uuidString, title: title, body: body)
                if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            }
        }
        if let sound = reaction.sound { environment.sounds.play(sound) }
    }

    /// The pane came to the front: clear anything that was waiting for the user.
    func didComeToFront() {
        if session.unseenOutput { session.unseenOutput = false }
        guard session.needsAttention else { return }
        session.needsAttention = false
        environment.notifier.clear(id: session.id.uuidString)
        environment.coordinator?.attentionDidChange()
    }

    private func showBellIndicator() {
        let caret = terminal.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        let overlay = view.overlay
        if let window = view.window, caret != .zero {
            let local = overlay.convert(window.convertFromScreen(caret), from: nil)
            let y = overlay.isFlipped ? local.minY : overlay.bounds.height - local.maxY
            session.alertAnchor = CGPoint(x: local.midX, y: max(16, y - 4))
        } else {
            session.alertAnchor = CGPoint(x: overlay.bounds.width - 24, y: 24)
        }
        let token = UUID()
        session.alertToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.session.alertToken == token else { return }
                self.session.alertToken = nil
            }
        }
    }

    // MARK: - Context menu

    func contextMenu() -> NSMenu {
        let menu = NSMenu(title: "Pane")
        let selection = terminal.getSelection() ?? ""
        let canPaste = NSPasteboard.general.string(forType: .string) != nil
        let directory = session.directory

        menu.addItem(ClosureMenuItem("Copy", key: "c", image: "doc.on.doc", enabled: !selection.isEmpty) { [weak self] in
            self?.terminal.copy(self as Any)
        })
        menu.addItem(ClosureMenuItem("Paste", key: "v", image: "doc.on.clipboard", enabled: canPaste) { [weak self] in
            self?.terminal.paste(self as Any)
        })
        menu.addItem(ClosureMenuItem("Select All", key: "a") { [weak self] in
            self?.terminal.selectAll()
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Split Right", key: "d", image: "rectangle.split.2x1") { [weak self] in
            guard let self else { return }
            self.host?.split(self, axis: .horizontal)
        })
        menu.addItem(ClosureMenuItem("Split Down", key: "d", modifiers: [.command, .shift], image: "rectangle.split.1x2") { [weak self] in
            guard let self else { return }
            self.host?.split(self, axis: .vertical)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Find…", key: "f", image: "magnifyingglass") { [weak self] in
            let item = NSMenuItem()
            item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
            self?.terminal.performFindPanelAction(item)
        })
        menu.addItem(ClosureMenuItem("Clear Buffer", key: "k", image: "eraser") { [weak self] in
            self?.clearBuffer()
        })
        menu.addItem(ClosureMenuItem("Restart Shell", image: "arrow.clockwise") { [weak self] in
            self?.restart()
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Open in Finder", image: "folder", enabled: !directory.isEmpty) {
            NSWorkspace.shared.open(URL(fileURLWithPath: directory))
        })
        menu.addItem(ClosureMenuItem("Copy Path", image: "link", enabled: !directory.isEmpty) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(directory, forType: .string)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Close Pane", key: "w", image: "xmark") { [weak self] in
            guard let self else { return }
            self.host?.requestClose(self)
        })
        return menu
    }

    // MARK: - Preferences & view actions

    func applyPreferences() {
        let theme = preferences.theme
        if CGFloat(preferences.fontSize) != baseFontSize {
            fontSize = max(7, fontSize + CGFloat(preferences.fontSize) - baseFontSize)
            baseFontSize = CGFloat(preferences.fontSize)
        }
        let font = preferences.font(size: fontSize)
        if terminal.font != font { terminal.font = font }
        terminal.nativeForegroundColor = theme.foreground
        terminal.nativeBackgroundColor = theme.background
        terminal.backgroundOpacity = 0
        terminal.caretColor = theme.accent
        terminal.caretTextColor = theme.background
        terminal.selectedTextBackgroundColor = theme.selection
        terminal.installColors(theme.terminalPalette)
        terminal.optionAsMetaKey = preferences.optionAsMeta
        view.apply(theme: theme, scanlines: preferences.scanlines)
    }

    func changeFontSize(by delta: CGFloat) {
        fontSize = min(72, max(7, fontSize + delta))
        applyPreferences()
    }

    func resetFontSize() {
        fontSize = CGFloat(preferences.fontSize)
        applyPreferences()
    }

    func clearBuffer() {
        terminal.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J")
        terminal.send(txt: "\u{0c}")
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let url = URL(string: directory), url.isFileURL else { return }
        let path = url.path(percentEncoded: false)
        guard path != session.directory else { return }
        session.directory = path
        refreshGitBranch()
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard !isShutDown else { return }
        timer?.invalidate()
        session.running = nil
        if preferences.exitBehavior.closesPane(exitCode: exitCode) {
            host?.paneDidFinish(self)
            return
        }
        session.exitStatus = .init(code: exitCode)
        view.setExitBannerVisible(true)
        if !ExitBehavior.closeIfClean.closesPane(exitCode: exitCode) { environment.sounds.play(.exit) }
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        Log.pane.error("Shell failed to start: \(String(describing: error), privacy: .public)")
        timer?.invalidate()
        session.exitStatus = .init(code: nil)
        view.setExitBannerVisible(true)
    }
}
