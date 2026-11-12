import AppKit
import Combine
import SwiftTerm
import SwiftUI
import CodecCore

/// What a pane needs from the window that holds it.
@MainActor
protocol PaneHost: AnyObject {
    /// Whether the user is looking at this pane: app active, window key, tab selected, pane focused.
    func isInFront(_ pane: Pane) -> Bool
    /// Splits `pane` along `axis`, the new pane after it (right or below) or before it (left or above).
    func split(_ pane: Pane, axis: SplitAxis, before: Bool)
    /// The user asked to close the pane; the host may confirm first.
    func requestClose(_ pane: Pane)
    /// The pane's shell is gone and the pane should be removed now.
    func paneDidFinish(_ pane: Pane)
    /// The shell asked for the history (↑ or ⌃R at the prompt), starting from what's typed.
    func showHistory(for pane: Pane, request: IntegrationEvent.HistoryRequest, typed: String)
    /// Explain Failure, from the terminal's context menu: show the command in the Commands sidebar and explain it.
    func explainFailure(of entry: TimelineEntry, in pane: Pane)
    /// ⌘-click on the name of a file in the terminal: show it in the editor, or a folder in Finder.
    func openFile(_ url: URL, from pane: Pane)
}

/// One shell in one pane: owns the process, the terminal view and the pane's `Session`.
@MainActor
final class Pane: LocalProcessTerminalViewDelegate {
    /// Posted when a command finishes: it may have changed the files or the repository, which the
    /// editor's marks of changed lines follow.
    static let commandDidFinish = Notification.Name("CodecPaneCommandDidFinish")
    /// Posted when the user decided whether to activate a virtual environment, its path the object:
    /// every pane asking about it takes the answer.
    static let venvDecided = Notification.Name("CodecPaneVenvDecided")

    let session = Session()
    /// Every command run here, for the Commands sidebar.
    let timeline = PaneTimeline()
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
    private var promptRefresh: AnyCancellable?
    private(set) var isShutDown = false
    private var fileLinkMonitor: Any?
    private var fileLinkObservers: [NSObjectProtocol] = []
    private var venvObserver: NSObjectProtocol?
    /// Virtual environments the user put off deciding about here: not asked about again in this pane.
    private var venvsPutOff: Set<String> = []
    /// One to activate this time only, once the shell is back at its prompt.
    private var venvToActivateOnce: String?
    /// Where the pointer is, in window coordinates; tests put it where they like.
    lazy var pointerLocation: () -> NSPoint? = { [weak self] in self?.terminal.window?.mouseLocationOutsideOfEventStream }

    /// A pane with a shell in `directory`, showing first what it showed last time when there's `contents`.
    init(directory: String?, environment: AppEnvironment, restoring contents: SavedPaneContents? = nil) {
        self.environment = environment
        fontSize = CGFloat(environment.preferences.fontSize)
        baseFontSize = fontSize
        view = PaneView(session: session, preferences: environment.preferences)
        view.onRestart = { [weak self] in self?.restart() }
        view.onDismiss = { [weak self] in
            guard let self else { return }
            self.host?.paneDidFinish(self)
        }
        view.onVenvDecision = { [weak self] venv, decision in self?.decide(venv, decision) }
        venvObserver = NotificationCenter.default.addObserver(forName: Self.venvDecided, object: nil, queue: .main) { [weak self] note in
            let path = note.object as? String
            MainActor.assumeIsolated {
                guard let self, let path else { return }
                let project = (path as NSString).deletingLastPathComponent
                let asking = self.session.pendingVenv?.path == path
                guard asking || self.session.directory == project || self.session.directory.hasPrefix(project + "/") else { return }
                // The shell looks again at the prompt: now, if it's waiting at one, or after the running command.
                if asking { self.session.pendingVenv = nil }
                self.refreshPrompt()
            }
        }

        terminal.processDelegate = self
        terminal.bellStyle = .sound
        terminal.onBell = { [weak self] in self?.handleBell() }
        terminal.contextMenuProvider = { [weak self] event in self?.contextMenu(at: event.locationInWindow) }
        terminal.shouldOwnPress = { [weak self] event in
            guard let self else { return false }
            return self.pressFile(event) || self.pressBranch(event) || self.beginCommandLineGesture(event)
        }
        terminal.onOwnedDrag = { [weak self] event in self?.continueCommandLineGesture(event) }
        terminal.onOwnedRelease = { [weak self] _ in
            guard let self else { return }
            if let file = self.pressedFile {
                self.pressedFile = nil
                self.view.fileLink.isPressed = false
                self.host?.openFile(file, from: self)
            } else if self.pressedBranch {
                self.pressedBranch = false
            } else {
                self.endCommandLineGesture()
            }
        }
        terminal.addSubview(branchHotspot)
        terminal.onDropFiles = { [weak self] urls in self?.insertPaths(urls) }
        // SwiftTerm doesn't let a subclass see ⌘ go down or the pointer move; a monitor can. While ⌘
        // is held, SwiftTerm has the window report every move. Letting go of ⌘ counts in any window, so
        // the line never outlasts it.
        fileLinkMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.terminal.window || !event.modifierFlags.contains(.command) else { return }
                self.refreshFileLink(modifiers: event.modifierFlags)
            }
            return event
        }
        // ⌘ can be let go where Codec doesn't hear it: in Finder after ⌘-clicking a folder, or after ⌘⇥.
        fileLinkObservers = [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let self, name == NSApplication.didResignActiveNotification
                        || sender == self.terminal.window.map(ObjectIdentifier.init) else { return }
                    self.hideFileLink(pointer: nil)
                }
            }
        }
        view.onScroll = { [weak self] in
            guard let self else { return }
            self.refreshCommandSeparators()
            if self.openableNames != nil { self.refreshFileLink(modifiers: self.fileLinkModifiers, rescan: true) }
        }
        view.onLayout = { [weak self] in self?.refreshCommandSeparators() }
        terminal.onRelease = { [weak self] clicks, dragged, point in
            self?.terminalGestureEnded(clicks: clicks, dragged: dragged, at: point)
        }
        terminal.onCopy = { [weak self] in self?.copyCommandLineSelection() ?? false }
        terminal.canCopy = { [weak self] in self?.hasCommandLineSelection ?? false }
        terminal.onCut = { [weak self] in self?.cutCommandLineSelection() }
        terminal.canCut = { [weak self] in self?.hasCommandLineSelection ?? false }
        let counter = activity
        terminal.setProcessOutputHandler { counter.tick() }
        let terminalOnAnyQueue = terminal
        oscObservation = terminal.observeOscEvents { [weak self] event in
            let payload = String(decoding: event.payload, as: UTF8.self)
            switch event.code {
            case 133 where payload == "B":
                // The prompt ends here; what follows on this row is the command line. Events arrive after
                // the parser has moved on, and a command typed ahead may be on screen already: the screen
                // only says where this prompt is if the cursor is still where the mark left it.
                let column = event.cursor.col
                let screen = terminalOnAnyQueue.terminalContentSnapshot(region: .history(maximumScrollbackRows: 0))
                    .flatMap { snapshot in
                        snapshot.cursorRow == snapshot.liveTopRow + event.cursor.row && snapshot.cursorColumn == column
                            ? Pane.screenRows(snapshot) : nil
                    }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.promptEndColumn = column
                        self?.promptWasDrawn(on: screen)
                    }
                }
            case 133 where payload == "C":
                // Output is about to start. Capture the screen right away, while the command line is
                // surely still on it; the block is worked out once zsh reports which command it was.
                let rows = terminalOnAnyQueue.terminalContentSnapshot(region: .history(maximumScrollbackRows: 500))
                    .map(Pane.screenRows)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.pendingCommandScreen = rows }
                }
            case IntegrationEvent.oscCode:
                guard let parsed = IntegrationEvent(payload: payload) else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.handle(parsed) }
                }
            default:
                return
            }
        }

        // A prompt waiting for a command shows a new prompt style straight away, not after the next command.
        promptRefresh = environment.promptWritten.sink { [weak self] in
            MainActor.assumeIsolated { self?.refreshPrompt() }
        }
        applyPreferences()
        session.directory = directory ?? NSHomeDirectory()
        if let contents { restore(contents) }
        start()
    }

    // MARK: - Keeping what it showed

    /// What the pane shows (its scrollback, up to the prompt it's at) and the commands it ran, to show
    /// them again later. Nil when there's nothing.
    func savedContents(at date: Date = Date()) -> SavedPaneContents? {
        var transcript = ""
        var firstRow = 0
        // A full-screen program has the screen: its scrollback isn't what's showing.
        if terminal.terminalInputStateSnapshot()?.isAlternateBuffer == false,
           let snapshot = terminal.terminalContentSnapshot(region: .history(maximumScrollbackRows: CodecTerminalView.scrollback)) {
            let end = newestBlockEnd ?? snapshot.cursorRow + 1
            var rows = snapshot.rows.filter { $0.absoluteRow < end }
            while let last = rows.last, last.text.trimmingCharacters(in: .whitespaces).isEmpty { rows.removeLast() }
            firstRow = rows.first?.absoluteRow ?? end
            transcript = TerminalTranscript.text(of: rows)
        }
        guard !transcript.isEmpty || !timeline.entries.isEmpty else { return nil }
        return SavedPaneContents(transcript: transcript, timeline: timeline.value.rebased(firstRow: firstRow),
                                 listStart: timeline.listStart, saved: date)
    }

    /// Shows what the pane showed last time, with a line to tell it from what comes next, and takes up
    /// its commands. Their rows are found again from the text once the terminal has its real width.
    private func restore(_ contents: SavedPaneContents) {
        if !contents.transcript.isEmpty {
            terminal.feed(text: contents.transcript)
            let when = contents.saved.formatted(date: .abbreviated, time: .shortened)
            // A blank line before the shell's first prompt. It also takes the hit when the terminal is
            // rewrapped for its real width just after the prompt, which can pull the prompt up a row.
            terminal.feed(text: "\u{1B}[2m── Restored · \(when) ──\u{1B}[0m\r\n\r\n")
        }
        timeline.restore(contents.timeline, listStart: contents.listStart)
        blocks.replace(with: contents.timeline.entries.compactMap(\.block))
        rowsMayHaveMoved = true
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
        let theme = preferences.theme
        env["CODEC_SELECTION_STYLE"] = "bg=" + theme.selection.hexString
        env["CODEC_SUGGESTIONS"] = preferences.suggestCommands ? "1" : "0"
        env["CODEC_HISTORY_KEYS"] = preferences.historyKeys ? "1" : "0"
        env["CODEC_COMPLETION"] = preferences.friendlyCompletion ? "1" : "0"
        env["CODEC_VENV"] = preferences.activateVenvs ? "1" : "0"
        // Suggestions in the theme's muted color; the completion menu's pick in its selection color.
        env["CODEC_SUGGESTION_STYLE"] = "fg=" + (theme.background.blended(withFraction: 0.45, of: theme.foreground) ?? theme.foreground).hexString
        env["CODEC_MENU_SELECTION"] = theme.selection.sgrBackground
        env["CODEC_EZA"] = preferences.ezaForLs ? "1" : "0"
        if preferences.colorFileListings {
            env = FileListingColors.environment(env, accent: theme.accent.sgrForeground)
        }
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
        timeline.abandonRunning()
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
        promptRefresh?.cancel()
        branchPopover?.close()
        if let fileLinkMonitor { NSEvent.removeMonitor(fileLinkMonitor) }
        fileLinkMonitor = nil
        fileLinkObservers.forEach(NotificationCenter.default.removeObserver)
        fileLinkObservers = []
        if let venvObserver { NotificationCenter.default.removeObserver(venvObserver) }
        venvObserver = nil
        if terminal.process.running { terminal.terminate() }
        environment.notifier.clear(id: session.id.uuidString)
    }

    /// What closing this pane would terminate: the program in the foreground and any background jobs.
    var runningPrograms: [String] {
        guard session.exitStatus == nil, terminal.process.running else { return [] }
        let shell = terminal.process.shellPid
        return RunningPrograms.names(shell: shell, foreground: ProcessInspector.foregroundProcess(ptyFD: terminal.process.childfd),
                                     children: ProcessInspector.children(of: shell), name: ProcessInspector.name(of:))
    }

    /// Closing this pane would end something besides the shell.
    var hasRunningJob: Bool { !runningPrograms.isEmpty }

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
        let printed = activity.drain() > 0
        if printed, !session.unseenOutput, host?.isInFront(self) == false {
            session.unseenOutput = true
        }
        if printed { view.finder.contentChanged() }
        if printed { refreshCommandSeparators() }
        if printed, openableNames != nil { refreshFileLink(modifiers: fileLinkModifiers, rescan: true) }
        ticks += 1
        if ticks % 4 == 0 { pollProcess() }
        if session.running != nil, timeline.running?.fullScreen == false,
           terminal.terminalInputStateSnapshot()?.isAlternateBuffer == true {
            timeline.markRunningFullScreen()
        }
        updateBranchHotspot()
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
        switch event {
        case .clipboard(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return
        case .commandText(let text):
            runningCommandText = text
            timeline.updateRunningCommand(text)
            // The whole command, which may be more than its first line.
            let usual = usualDuration(of: text)
            if session.running != nil, session.running?.usual != usual { session.running?.usual = usual }
            timeline.setRunningUsualDuration(usual)
            return
        case .historyFile(let path):
            environment.history.useShellFile(URL(fileURLWithPath: path))
            return
        case .historyRequest(let request, let typed):
            host?.showHistory(for: self, request: request, typed: typed)
            return
        case .toolchain:
            session.apply(event)
            if let pending = session.pendingVenv, venvsPutOff.contains(pending.path) { session.pendingVenv = nil }
            return
        case .commandStarted:
            runningCommandText = nil
            runningDirectory = session.directory
            promptIsDrawn = false
            waitingPromptRow = nil
        default:
            break
        }
        let command = session.running?.command ?? ""
        let started = session.running?.started
        session.apply(event)
        // Answered while a command ran: the prompt is back.
        if case .prompt = event, venvToActivateOnce != nil { activateVenvOnceIfAtPrompt() }
        if case .commandStarted(let started) = event {
            var block: CommandBlocks.Block?
            if let screen = pendingCommandScreen {
                pendingCommandScreen = nil
                block = CommandBlocks.locate(command: started, in: screen.rows, cursorRow: screen.cursorRow,
                                             promptLines: session.promptLines)
            }
            if let block {
                // The new command isn't listed yet: the ones before it are above its prompt.
                relocateBlocksIfNeeded(above: block.prompt)
                captureFinishedOutput(end: block.prompt)
                // Rows only grow; going back means the scrollback was cleared under the older commands.
                if let last = blocks.blocks.last, block.prompt <= last.prompt { timeline.forgetBlocks() }
                blocks.record(block)
            }
            let usual = usualDuration(of: started)
            session.running?.usual = usual
            timeline.begin(command: started, directory: session.directory, started: session.running?.started ?? Date(),
                           block: block, usualDuration: usual, toolchain: session.toolchain)
            refreshCommandSeparators()
        }
        guard case .commandFinished(let exitCode, let duration) = event else { return }
        let finished = timeline.running
        let usual = finished?.usualDuration
        timeline.finish(exitCode: exitCode, duration: duration, output: nil)
        // Its output runs up to the next prompt, found once that's drawn.
        if let finished, finished.block != nil, !finished.fullScreen { outputToCapture = finished.id }
        if preferences.recordHistory {
            environment.history.record(HistoryEntry(
                command: runningCommandText ?? command, date: started ?? Date().addingTimeInterval(-duration),
                directory: runningDirectory ?? session.directory, exitCode: exitCode, duration: duration))
        }
        runningCommandText = nil
        refreshGitBranch()
        NotificationCenter.default.post(name: Self.commandDidFinish, object: self)
        let reaction = preferences.attentionPolicy.reactionToFinishedCommand(
            duration: duration, paneInFront: host?.isInFront(self) ?? false)
        let program = CommandNames.program(of: command)
        var outcome = "\(exitCode == 0 ? "Completed" : "Exit status \(exitCode)") after \(Formatting.duration(duration))"
        if exitCode == 0, let usual {
            switch UsualDuration.Comparison(duration: duration, usual: usual) {
            case .asUsual: outcome += ", as usual"
            case .slower(let ratio): outcome += ", \(UsualDuration.Comparison.slower(ratio).multiplier) its usual \(Formatting.seconds(usual))"
            case .faster: outcome += ", faster than its usual \(Formatting.seconds(usual))"
            }
        }
        perform(reaction,
                title: exitCode == 0 ? "“\(program)” finished" : "“\(program)” failed",
                body: "\(outcome) · \(session.abbreviatedDirectory)")
    }

    /// The user's answer about activating a virtual environment: remembered for every pane when they
    /// allowed or refused it; only in this one when they put it off or took it this time only.
    func decide(_ venv: Toolchain.PythonEnvironment, _ answer: VenvAnswer) {
        let decision: VenvDecisions.Decision
        switch answer {
        case .always: decision = .allow
        case .never: decision = .deny
        case .notNow:
            venvsPutOff.insert(venv.path)
            if session.pendingVenv?.path == venv.path { session.pendingVenv = nil }
            return
        case .once:
            // The shell activates the one it's asking about, which is this one while we're still in its project.
            if session.pendingVenv?.path == venv.path { session.pendingVenv = nil }
            venvToActivateOnce = venv.path
            activateVenvOnceIfAtPrompt()
            return
        }
        do {
            try environment.shellIntegration?.venvDecisions.set(decision, for: venv.path)
        } catch {
            Log.pane.error("Couldn't record the answer about \(venv.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return NSSound.beep()
        }
        NotificationCenter.default.post(name: Self.venvDecided, object: venv.path)
    }

    private func activateVenvOnceIfAtPrompt() {
        guard let path = venvToActivateOnce, isAtCommandLine else { return }
        venvToActivateOnce = nil
        let project = (path as NSString).deletingLastPathComponent
        guard session.directory == project || session.directory.hasPrefix(project + "/") else { return }
        terminal.send(CommandLineEditing.Action.activateVenvOnce.sequence)
    }

    /// How long `command` usually takes here, from the history; nil when that's not known, or not shown.
    func usualDuration(of command: String) -> TimeInterval? {
        guard preferences.showUsualDuration else { return nil }
        return UsualDuration.of(command, in: runningDirectory ?? session.directory, history: environment.history.history.entries)
    }

    func jumpToCommand(previous: Bool) {
        let row = previous ? terminal.previousSemanticPromptRow() : terminal.nextSemanticPromptRow()
        if let row {
            terminal.scrollTo(row: row)
        } else if !previous {
            terminal.scrollTo(row: Int.max)
        }
    }

    // MARK: - Editing the command line

    /// The shell is waiting at its prompt with Codec's integration loaded, so its command line can be
    /// edited like a text field. Never true while a program runs, so editing keys can't reach it.
    var isAtCommandLine: Bool {
        session.integrated && session.running == nil && session.exitStatus == nil && !isShutDown
            && terminal.terminalInputStateSnapshot()?.isAlternateBuffer == false
    }

    /// Part of the command line is selected: zsh's region, the only highlight on the command line.
    var hasCommandLineSelection: Bool {
        isAtCommandLine && session.commandLineSelection
    }

    /// A gesture Codec owns on the command line: measured against the cursor where the press began,
    /// since zsh moves the cursor while it runs.
    private struct CommandLineGesture {
        var caret: CGRect
        var columns: Int
        var anchor: Int
        var dragOffset = 0
    }

    private var commandLineGesture: CommandLineGesture?

    /// Takes a plain press on the command line's row: click to place the cursor, drag to select,
    /// double-click for a word, triple-click for the whole command. Elsewhere, the terminal handles it.
    func beginCommandLineGesture(_ event: NSEvent) -> Bool {
        guard isAtCommandLine, event.type == .leftMouseDown,
              event.modifierFlags.intersection([.shift, .option, .command, .control]).isEmpty,
              terminal.currentMouseMode == .off,
              let grid = TerminalGrid(terminal: terminal),
              let hit = CommandLineEditing.hit(event.locationInWindow, caret: grid.caret), hit.row == 0 else { return false }
        terminal.selectNone()
        commandLineGesture = nil
        switch event.clickCount {
        case 1:
            terminal.send(CommandLineEditing.press(at: hit.boundary))
            commandLineGesture = CommandLineGesture(caret: grid.caret, columns: grid.columns, anchor: hit.boundary)
        case 2:
            // The first click put the cursor there.
            terminal.send(CommandLineEditing.Action.selectWord.sequence)
        default:
            terminal.send(CommandLineEditing.Action.selectAll.sequence)
        }
        return true
    }

    func continueCommandLineGesture(_ event: NSEvent) {
        guard var gesture = commandLineGesture,
              let hit = CommandLineEditing.hit(event.locationInWindow, caret: gesture.caret) else { return }
        let offset = CommandLineEditing.offset(of: hit, columns: gesture.columns) - gesture.anchor
        guard offset != gesture.dragOffset else { return }
        terminal.send(CommandLineEditing.drag(to: offset))
        gesture.dragOffset = offset
        commandLineGesture = gesture
    }

    func endCommandLineGesture() {
        commandLineGesture = nil
        // zsh copies only if something ended up selected.
        if preferences.copyOnSelect { terminal.send(CommandLineEditing.Action.copy.sequence) }
    }

    /// Copies the command-line selection. False when the terminal's own selection should be copied.
    func copyCommandLineSelection() -> Bool {
        guard !terminal.selectionActive, hasCommandLineSelection else { return false }
        terminal.send(CommandLineEditing.Action.copy.sequence)
        return true
    }

    /// Copies the selected part of the command line and removes it.
    func cutCommandLineSelection() {
        guard hasCommandLineSelection else { return }
        terminal.send(CommandLineEditing.Action.cut.sequence)
    }

    /// Runs a command-line editing action. Outside Codec's zsh, falls back to readline's keys where
    /// they mean the same thing, and does nothing in full-screen programs.
    func editCommandLine(_ action: CommandLineEditing.Action) {
        if isAtCommandLine {
            terminal.send(action.sequence)
        } else if session.exitStatus == nil, terminal.terminalInputStateSnapshot()?.isAlternateBuffer == false,
                  let fallback = action.readlineFallback {
            terminal.send(fallback)
        }
    }

    // MARK: - Selecting text

    /// After the terminal handled a click or drag: widen double-click selections to the whole token,
    /// and copy the selection when copy-on-select is on.
    func terminalGestureEnded(clicks: Int, dragged: Bool, at point: NSPoint) {
        if clicks == 2, !dragged, terminal.currentMouseMode == .off {
            selectWholeToken(at: point)
        }
        if preferences.copyOnSelect, terminal.selectionActive, let text = terminal.getSelection(), !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// Selects the path, URL, email, `host:port`… under a point, where the terminal's own word
    /// selection stops at punctuation.
    func selectWholeToken(at point: NSPoint) {
        guard let grid = TerminalGrid(terminal: terminal), let token = token(at: point, in: grid),
              terminal.getSelection() != token.text else { return }
        terminal.selectByDragging(from: grid.center(row: token.first.row, column: token.first.column),
                                  to: grid.trailingEdge(row: token.last.row, column: token.last.column))
    }

    /// The token under a window point, as a double-click selects it, with its first and last cells.
    private func token(at point: NSPoint, in grid: TerminalGrid)
        -> (text: String, first: (row: Int, column: Int), last: (row: Int, column: Int))? {
        let cell = grid.cell(at: point)
        guard let line = grid.logicalLine(containing: cell.row),
              let index = line.cells.firstIndex(where: { $0.row == cell.row && $0.column == cell.column }),
              let range = SmartSelection.range(in: line.characters, at: index) else { return nil }
        return (String(line.characters[range]), line.cells[range.lowerBound], line.cells[range.upperBound - 1])
    }

    // MARK: - Opening files

    /// A file or folder ⌘-pressed, opened when the press ends.
    private var pressedFile: URL?

    /// Takes a ⌘-click on the name of a file or folder that exists, as `ls` lists it or a compiler
    /// reports it. Anything else, URLs included, the terminal handles.
    func pressFile(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown, event.clickCount == 1,
              event.modifierFlags.intersection([.shift, .option, .command, .control]) == .command,
              terminal.currentMouseMode == .off,
              let path = file(at: event.locationInWindow) else { return false }
        pressedFile = URL(fileURLWithPath: path)
        view.fileLink.isPressed = true
        return true
    }

    /// The file or folder named at a window point. Its name is relative to where the command that
    /// printed it ran, or to a folder the command was given (`ls Sources`); on the command line being
    /// typed, to the shell's directory.
    func file(at point: NSPoint) -> String? {
        guard let grid = TerminalGrid(terminal: terminal), let token = token(at: point, in: grid) else { return nil }
        return file(named: token.text, at: grid.viewportTop + token.first.row)
    }

    private func file(named name: String, at row: Int) -> String? {
        let entry = newestBlockEnd.map { row < $0 } == true ? command(atRow: row) : nil
        let directories = FileReference.directories(command: entry?.command ?? "", in: entry?.directory ?? session.directory)
        return FileReference.resolve(name, in: directories)
    }

    /// A name on screen that a ⌘-click would open.
    private struct OpenableName {
        var text: String
        var first: (row: Int, column: Int)
        var last: (row: Int, column: Int)
        var path: String

        func contains(_ cell: (row: Int, column: Int)) -> Bool {
            (cell.row, cell.column) >= (first.row, first.column) && (cell.row, cell.column) <= (last.row, last.column)
        }
    }

    /// Every name on screen ⌘ would open, found when ⌘ went down and again when the screen changes,
    /// so moving the pointer doesn't ask the disk. Nil while ⌘ is up.
    private var openableNames: [OpenableName]?
    private var isPointingAtFile = false
    /// The modifiers when the marks were last drawn, to redraw them with when the screen changes.
    private var fileLinkModifiers: NSEvent.ModifierFlags = []

    /// Marks what ⌘ would open, if ⌘ is down, or takes the marks away.
    func refreshFileLink(modifiers: NSEvent.ModifierFlags, rescan: Bool = false) {
        guard let point = pointerLocation() else { return hideFileLink(pointer: nil) }
        updateFileLink(at: point, modifiers: modifiers, rescan: rescan)
    }

    /// While ⌘ is down, marks every name on screen a click would open, and the one under the pointer
    /// most, with a tag saying what opens and the pointing hand. Otherwise takes the marks away.
    func updateFileLink(at point: NSPoint, modifiers: NSEvent.ModifierFlags, rescan: Bool = false) {
        guard !isShutDown, modifiers.intersection([.shift, .option, .command, .control]) == .command,
              terminal.currentMouseMode == .off, terminal.window != nil,
              let grid = TerminalGrid(terminal: terminal) else {
            return hideFileLink(pointer: point)
        }
        fileLinkModifiers = modifiers
        if rescan || openableNames == nil { openableNames = openableNames(in: grid) }
        let names = openableNames ?? []
        let cell = grid.cell(at: point)
        let hovered = terminal.bounds.contains(terminal.convert(point, from: nil))
            ? names.firstIndex { $0.contains(cell) } : nil
        let link = view.fileLink
        link.font = terminal.font
        func frames(_ name: OpenableName) -> [NSRect] {
            (name.first.row...name.last.row).map { row in
                let start = row == name.first.row ? name.first.column : 0
                let end = row == name.last.row ? name.last.column + 1 : grid.columns
                return link.convert(grid.frame(row: row, columns: start..<end), from: nil)
            }
        }
        link.show(marks: names.indices.filter { $0 != hovered }.flatMap { frames(names[$0]) },
                  frames: hovered.map { frames(names[$0]) } ?? [],
                  tag: hovered.map { fileLinkTag(names[$0].path, named: names[$0].text) })
        if hovered != nil {
            NSCursor.pointingHand.set()
        } else if isPointingAtFile, terminal.bounds.contains(terminal.convert(point, from: nil)) {
            NSCursor.iBeam.set()
        }
        isPointingAtFile = hovered != nil
    }

    /// Every name on the screen that's a file or folder, each looked for where the command that printed
    /// it ran. The prompt's are marked too: only command blocks tell its lines from output, a prompt
    /// where only Return was pressed has none, and a block found in the wrong place would leave output
    /// unmarked.
    private func openableNames(in grid: TerminalGrid) -> [OpenableName] {
        relocateBlocksIfNeeded()
        let end = newestBlockEnd
        var known: [Int: [String]] = [:]
        func directories(forRow row: Int) -> [String] {
            let index = end.map { row < $0 } == true ? blocks.index(containing: row) : nil
            if let directories = known[index ?? -1] { return directories }
            let entry = index.flatMap { index in timeline.entries.last { $0.block == blocks.blocks[index] } }
            let found = FileReference.directories(command: entry?.command ?? "", in: entry?.directory ?? session.directory)
            known[index ?? -1] = found
            return found
        }
        var names: [OpenableName] = []
        var row = 0
        // A screen full of names is a few hundred; past that, it's not worth asking the disk about more.
        while row < grid.rows.count, names.count < 400 {
            guard let line = grid.logicalLine(containing: row) else { break }
            defer { row = max(row + 1, (line.cells.last?.row ?? row) + 1) }
            var index = 0
            while index < line.characters.count {
                guard let range = SmartSelection.range(in: line.characters, at: index) else {
                    index += 1
                    continue
                }
                let text = String(line.characters[range])
                let first = line.cells[range.lowerBound], last = line.cells[range.upperBound - 1]
                if let path = FileReference.resolve(text, in: directories(forRow: grid.viewportTop + first.row)) {
                    names.append(OpenableName(text: text, first: first, last: last, path: path))
                }
                index = range.upperBound
            }
        }
        return names
    }

    /// What the tag beside the name under the pointer shows: the file's icon, and the path that opens
    /// when it's more than the name says.
    private func fileLinkTag(_ path: String, named name: String) -> FileLinkView.Tag {
        let file = (path as NSString).lastPathComponent
        let theme = preferences.theme
        let icon = FileReference.isDirectory(path)
            ? FileIcons.image(for: FolderType.of(folderNamed: file), state: .closed, theme: theme)
            : FileIcons.image(for: FileType.of(fileNamed: file), theme: theme)
        return FileLinkView.Tag(icon: icon, path: FileReference.label(for: path, named: name, from: session.directory))
    }

    private func hideFileLink(pointer point: NSPoint?) {
        openableNames = nil
        guard view.fileLink.isShowing else { return }
        view.fileLink.show(marks: [], frames: [], tag: nil)
        if isPointingAtFile, let point, terminal.bounds.contains(terminal.convert(point, from: nil)) { NSCursor.iBeam.set() }
        isPointingAtFile = false
    }

    /// The command, running or finished, whose prompt or output holds an absolute row.
    private func command(atRow row: Int) -> TimelineEntry? {
        relocateBlocksIfNeeded()
        guard let index = blocks.index(containing: row) else { return nil }
        let block = blocks.blocks[index]
        return timeline.entries.last { $0.block == block }
    }

    // MARK: - Command output

    /// Where each command's prompt and output begin.
    private(set) var blocks = CommandBlocks()
    /// The screen as it was when the newest command's output began.
    private var pendingCommandScreen: (rows: [ScreenRow], cursorRow: Int)?

    nonisolated static func screenRows(_ snapshot: TerminalContentSnapshot) -> (rows: [ScreenRow], cursorRow: Int) {
        (snapshot.rows.map { ScreenRow(row: $0.absoluteRow, text: $0.text, isWrapped: $0.isWrapped) }, snapshot.cursorRow)
    }

    /// Where the newest block ends: the current prompt's first row at the prompt, or past the last line
    /// while a command runs.
    private var newestBlockEnd: Int? {
        guard let snapshot = terminal.terminalContentSnapshot(region: .history(maximumScrollbackRows: 0)) else { return nil }
        guard session.running == nil, session.integrated else { return snapshot.cursorRow + 1 }
        let screen = Pane.screenRows(snapshot)
        return CommandBlocks.promptStart(cursorRow: screen.cursorRow, in: screen.rows, promptLines: session.promptLines)
    }

    /// The output of the command whose block holds a window point.
    func outputRange(at point: NSPoint) -> Range<Int>? {
        relocateBlocksIfNeeded()
        guard let grid = TerminalGrid(terminal: terminal), let end = newestBlockEnd,
              let index = blocks.index(containing: grid.viewportTop + grid.cell(at: point).row) else { return nil }
        return blocks.outputRange(of: index, end: end)
    }

    /// The finished command whose prompt or output is at `point` (window coordinates), or else the
    /// most recent one that finished.
    func finishedEntry(at point: NSPoint?) -> TimelineEntry? {
        relocateBlocksIfNeeded()
        if let point, let grid = TerminalGrid(terminal: terminal),
           let index = blocks.index(containing: grid.viewportTop + grid.cell(at: point).row) {
            let block = blocks.blocks[index]
            return timeline.entries.last { $0.block == block && !$0.isRunning }
        }
        return timeline.entries.last { !$0.isRunning }
    }

    /// The output of the most recent command that has finished.
    var lastOutputRange: Range<Int>? {
        relocateBlocksIfNeeded()
        guard let last = blocks.blocks.indices.last, let end = newestBlockEnd else { return nil }
        let index = session.running == nil ? last : last - 1
        return blocks.outputRange(of: index, end: end)
    }

    /// The text of some rows, with soft-wrapped lines rejoined and trailing blank space removed.
    func text(of range: Range<Int>) -> String? {
        var lines = self.lines(of: range).lines
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The lines in some rows, soft-wrapped ones rejoined, and whether the first rows had already left
    /// the scrollback. Copies only as much of the scrollback as the rows need.
    func lines(of range: Range<Int>) -> (lines: [String], lostEarlier: Bool) {
        guard !range.isEmpty, let live = terminal.terminalContentSnapshot(region: .history(maximumScrollbackRows: 0)),
              let snapshot = terminal.terminalContentSnapshot(region: .history(maximumScrollbackRows: min(
                  max(live.liveTopRow - range.lowerBound, 0), CodecTerminalView.scrollback))) else { return ([], false) }
        var lines: [String] = []
        for row in snapshot.rows where range.contains(row.absoluteRow) {
            let text = row.text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            if row.isWrapped, !lines.isEmpty { lines[lines.count - 1] += text } else { lines.append(text) }
        }
        return (lines, snapshot.capturedRange.lowerBound > range.lowerBound)
    }

    func copyOutput(_ range: Range<Int>) {
        guard let text = text(of: range) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Selects some rows on screen, scrolling to bring them in when needed.
    func selectOutput(_ range: Range<Int>) {
        guard var grid = TerminalGrid(terminal: terminal), !range.isEmpty else { return }
        let visibleRows = grid.rows.count
        if !(grid.viewportTop..<(grid.viewportTop + visibleRows)).contains(range.lowerBound) {
            terminal.scrollTo(row: range.lowerBound - grid.bufferRowOffset)
            guard let scrolled = TerminalGrid(terminal: terminal) else { return }
            grid = scrolled
        }
        let first = range.lowerBound - grid.viewportTop, last = range.upperBound - 1
        let lastColumn = grid.columns - 1
        if last < grid.viewportTop + visibleRows {
            terminal.selectByDragging(from: grid.center(row: first, column: 0),
                                      to: grid.trailingEdge(row: last - grid.viewportTop, column: lastColumn))
            return
        }
        // Taller than the screen: start here, then scroll to the end and extend, as Shift-click does.
        terminal.selectByDragging(from: grid.center(row: first, column: 0), to: grid.trailingEdge(row: first, column: lastColumn))
        terminal.scrollTo(row: last - grid.bufferRowOffset - visibleRows + 1)
        guard let end = TerminalGrid(terminal: terminal) else { return }
        terminal.extendSelection(to: end.trailingEdge(row: last - end.viewportTop, column: lastColumn))
    }

    // MARK: - Going back to a command

    /// The command that finished, whose output is kept once the prompt after it is on screen.
    private var outputToCapture: Int?

    /// The prompt is drawn (zsh just printed its 133;B mark), so the finished command's output can be
    /// told from it: it ends where this prompt starts on `screen`, the screen as the prompt was drawn.
    /// Without one (something was typed ahead), it's kept once the next command starts, from where
    /// that command's prompt is found.
    private func promptWasDrawn(on screen: (rows: [ScreenRow], cursorRow: Int)?) {
        promptIsDrawn = true
        defer { refreshCommandSeparators() }
        guard let screen else { return }
        let start = CommandBlocks.promptStart(cursorRow: screen.cursorRow, in: screen.rows, promptLines: session.promptLines)
        waitingPromptRow = start
        if outputToCapture != nil {
            relocateBlocksIfNeeded()
            captureFinishedOutput(end: start)
        }
        // `clear` and ⌃L leave the commands that were on screen with nothing to show for themselves.
        if !rowsMayHaveMoved { blocks.forgetBlocksGone(from: screen.rows) }
    }

    /// Keeps what the command that just finished printed, up to `end`: the first row of the prompt after it.
    private func captureFinishedOutput(end: Int) {
        guard let id = outputToCapture else { return }
        outputToCapture = nil
        guard let block = timeline.value.entry(id: id)?.block, end > block.output else { return }
        let (lines, lostEarlier) = lines(of: block.output..<end)
        let output = CapturedOutput(lines: lines, lostEarlier: lostEarlier)
        if !output.isEmpty { timeline.setOutput(output, of: id) }
    }

    /// The rows a command's prompt, command line and output take up, while they're still in the scrollback
    /// as they were: nil once they've scrolled out of it, the buffer was cleared, or a full-screen program
    /// has the screen.
    func rows(of entry: TimelineEntry) -> Range<Int>? {
        relocateBlocksIfNeeded()
        guard let entry = timeline.value.entry(id: entry.id) else { return nil }
        if let rows = rowsAsRecorded(of: entry) { return rows }
        // The rows may have moved without word of a resize: look once more before giving up on it.
        rowsMayHaveMoved = true
        relocateBlocksIfNeeded()
        guard let moved = timeline.value.entry(id: entry.id), moved.block != entry.block,
              let rows = rowsAsRecorded(of: moved) else {
            timeline.forgetBlock(of: entry.id)
            return nil
        }
        return rows
    }

    private func rowsAsRecorded(of entry: TimelineEntry) -> Range<Int>? {
        guard let block = entry.block, session.exitStatus == nil,
              terminal.terminalInputStateSnapshot()?.isAlternateBuffer == false,
              let grid = TerminalGrid(terminal: terminal) else { return nil }
        // The scrollback's first row, past which rows have been dropped.
        guard block.prompt >= grid.bufferRowOffset else { return nil }
        let commandLine = block.output - 1
        guard let live = terminal.terminalContentSnapshot(region: .history(maximumScrollbackRows: 0)),
              let snapshot = terminal.terminalContentSnapshot(region: .history(maximumScrollbackRows: min(
                  max(live.liveTopRow - block.prompt, 0), CodecTerminalView.scrollback))) else { return nil }
        let screen = Pane.screenRows(snapshot)
        // Row numbers start over when the scrollback is cleared, so check the command is still on its line.
        guard CommandBlocks.locate(command: entry.screenCommand, line: block.commandLine, in: screen.rows,
                                   cursorRow: commandLine, promptLines: 1)?.output == block.output else { return nil }
        let end: Int
        if let index = blocks.blocks.firstIndex(of: block), let next = blocks.blocks.dropFirst(index + 1).first {
            end = next.prompt
        } else if entry.isRunning || !session.integrated {
            end = screen.cursorRow + 1
        } else {
            end = CommandBlocks.promptStart(cursorRow: screen.cursorRow, in: screen.rows, promptLines: session.promptLines)
        }
        return block.prompt..<max(end, block.output)
    }

    /// The terminal rewrapped its lines (it was resized), so commands may be on other rows now.
    private var rowsMayHaveMoved = false

    /// Finds every command's rows again from the screen's content, after the terminal rewrapped its lines.
    /// They're looked for above `row`, by default where the newest command ends.
    private func relocateBlocksIfNeeded(above row: Int? = nil) {
        guard rowsMayHaveMoved, session.exitStatus == nil,
              terminal.terminalInputStateSnapshot()?.isAlternateBuffer == false,
              let end = row ?? newestBlockEnd,
              let snapshot = terminal.terminalContentSnapshot(region: .history(maximumScrollbackRows: CodecTerminalView.scrollback))
        else { return }
        rowsMayHaveMoved = false
        let placed = timeline.entries.filter { $0.block != nil }
        let found = CommandBlocks.relocate(commands: placed.map { ($0.screenCommand, $0.block?.commandLine) },
                                           in: Pane.screenRows(snapshot).rows, lastRow: end - 1,
                                           promptLines: session.promptLines)
        timeline.setBlocks(Dictionary(uniqueKeysWithValues: zip(placed.map(\.id), found)))
        blocks.replace(with: found.compactMap { $0 }, dropped: found.prefix { $0 == nil }.count)
    }

    // MARK: - Telling commands apart

    /// The shell has drawn the prompt it's waiting at. Not so between a command finishing and its
    /// prompt, when what's on screen still ends with the command's output.
    private var promptIsDrawn = false
    /// That prompt's first row, from where zsh marked its end. Nil when the mark came too late to say
    /// (something was typed ahead) or the terminal was resized since; the row is worked out from the
    /// cursor then.
    private var waitingPromptRow: Int?
    private var relocationToken = 0

    /// Draws what sets the commands on screen apart, as the settings say: a line above each one's
    /// prompt, with a bar in the margin beside one that failed or is running, and a shade behind every
    /// other one, from its line to the next. The prompt waiting for a command counts as one. Only with
    /// shell integration, which is what tells commands apart.
    func refreshCommandSeparators() {
        let separators = view.commandSeparators
        let lines = preferences.commandSeparators, shading = preferences.shadeAlternateCommands
        guard lines || shading, session.integrated, !isShutDown, promptIsDrawn || !blocks.blocks.isEmpty,
              terminal.terminalInputStateSnapshot()?.isAlternateBuffer == false else {
            return separators.update()
        }
        // Finding the commands again takes the whole scrollback: once a resize is over, not at each step of it.
        if rowsMayHaveMoved, !blocks.blocks.isEmpty {
            separators.update()
            return relocateBlocksSoon()
        }
        // One copy of the screen where `TerminalGrid` takes two: this runs at every frame of a scroll.
        let caret = terminal.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        guard let window = terminal.window, caret.height > 0,
              let snapshot = terminal.terminalContentSnapshot(region: .viewport),
              let top = snapshot.rows.first?.absoluteRow else { return separators.update() }
        let shown = top..<(top + snapshot.rows.count)
        let cursorRow = snapshot.cursorRow
        func isBlank(_ row: Int) -> Bool { snapshot.rows[row - top].text.allSatisfy(\.isWhitespace) }
        var waiting: Range<Int>?
        if promptIsDrawn {
            let start: Int
            if let row = waitingPromptRow, row <= cursorRow {
                start = row
            } else {
                start = CommandBlocks.promptStart(cursorRow: cursorRow, in: Pane.screenRows(snapshot).rows,
                                                  promptLines: session.promptLines)
            }
            // And what the line editor shows under the cursor: the rest of a long command, a list of completions.
            var last = max(cursorRow, start)
            while shown.contains(last + 1), !isBlank(last + 1) { last += 1 }
            waiting = start..<(last + 1)
        }
        // While a command runs, or before its prompt is drawn, the newest one's output ends at the cursor.
        let spans = blocks.spans(overlapping: shown, end: waiting?.lowerBound ?? cursorRow + 1, waitingPrompt: waiting)

        let bounds = separators.bounds
        let text = separators.convert(terminal.bounds, from: terminal)
        // Rows are laid out from the terminal's top edge, each as tall as the caret: see `TerminalGrid`.
        let terminalFrame = terminal.convert(terminal.bounds, to: nil)
        let rowHeight = window.convertFromScreen(caret).height
        func frame(ofRow row: Int) -> NSRect {
            separators.convert(NSRect(x: terminalFrame.minX, y: terminalFrame.maxY - CGFloat(row - top + 1) * rowHeight,
                                      width: terminalFrame.width, height: rowHeight), from: nil)
        }
        // Where each command starts: the top of its prompt, or the middle of the blank line a prompt
        // begins with, as Codec's does, so the line has as much room above it as below.
        let tops = spans.map { span -> CGFloat in
            guard shown.contains(span.rows.lowerBound) else { return bounds.maxY }
            let first = frame(ofRow: span.rows.lowerBound)
            return isBlank(span.rows.lowerBound) && span.rows.count > 1 ? first.midY : first.maxY
        }
        var shades: [CommandSeparatorView.Shade] = [], rules: [NSRect] = [], marks: [CommandSeparatorView.Mark] = []
        for (index, span) in spans.enumerated() {
            let top = tops[index]
            // Where it ends: at the next one's line, past the screen's edge (so into the pane's padding),
            // or, for the newest, under its last row.
            let endsOnScreen = index + 1 == spans.count && span.rows.upperBound < shown.upperBound
            let bottom = index + 1 < spans.count ? tops[index + 1]
                : endsOnScreen ? frame(ofRow: span.rows.upperBound - 1).minY : bounds.minY
            guard top > bottom else { continue }
            // Nothing is above the very first row to set a command apart from.
            if lines, shown.contains(span.rows.lowerBound), span.rows.lowerBound > 0 {
                rules.append(NSRect(x: text.minX, y: top - 0.5, width: text.width, height: 1))
            }
            if lines, let kind = markKind(of: span) {
                // In the margin, where the mark over a command gone back to is, and short of the lines
                // at either end unless the command goes on past the screen's edge.
                let gap: CGFloat = top - bottom > 12 ? 3 : 0
                let upper = top < bounds.maxY ? top - gap : top, lower = bottom > bounds.minY ? bottom + gap : bottom
                marks.append(.init(frame: NSRect(x: max(text.minX - 9, 2), y: lower, width: 3, height: upper - lower), kind: kind))
            }
            guard shading, span.isAlternate else { continue }
            // The newest one isn't over: instead of an edge, its shade fades out over a row below its last.
            let fade = endsOnScreen && span.isNewest ? rowHeight : 0
            shades.append(.init(frame: NSRect(x: bounds.minX, y: bottom - fade, width: bounds.width, height: top - bottom + fade),
                                fade: fade))
        }
        separators.update(shades: shades, rules: rules, marks: marks)
    }

    /// What the bar beside a command says, when there's something to say: it's running, or it failed.
    /// Nothing for one that worked, nor for the prompt waiting for one.
    private func markKind(of span: CommandBlocks.Span) -> CommandSeparatorView.Mark.Kind? {
        guard let index = span.block, blocks.blocks.indices.contains(index) else { return nil }
        let block = blocks.blocks[index]
        guard let entry = timeline.entries.last(where: { $0.block == block }) else { return nil }
        return entry.isRunning ? .running : entry.failed ? .failed : nil
    }

    /// Finds the commands again a moment after the last resize, then draws what sets them apart.
    private func relocateBlocksSoon() {
        relocationToken += 1
        let token = relocationToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.relocationToken == token, !self.isShutDown else { return }
                self.relocateBlocksIfNeeded()
                if !self.rowsMayHaveMoved { self.refreshCommandSeparators() }
            }
        }
    }

    /// The output part of `rows(of:)`.
    func liveOutputRange(of entry: TimelineEntry) -> Range<Int>? {
        guard let rows = rows(of: entry), let block = timeline.value.entry(id: entry.id)?.block,
              block.output < rows.upperBound else { return nil }
        return block.output..<rows.upperBound
    }

    /// Scrolls the terminal back to a command and marks it. With a query, goes to the first line of its
    /// output that holds it. False when the command isn't in the scrollback anymore.
    @discardableResult
    func reveal(_ entry: TimelineEntry, matching query: String = "") -> Bool {
        // Looked up again: the rows may have moved since the caller got its copy.
        guard let rows = rows(of: entry), var grid = TerminalGrid(terminal: terminal),
              let entry = timeline.value.entry(id: entry.id), let block = entry.block else { return false }
        terminal.selectNone()
        var target = block.output - 1
        if !query.isEmpty, block.output < rows.upperBound,
           let snapshot = terminal.terminalContentSnapshot(region: .history(maximumScrollbackRows: CodecTerminalView.scrollback)) {
            let output = snapshot.rows.filter { (block.output..<rows.upperBound).contains($0.absoluteRow) }
            if let match = output.first(where: { $0.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) {
                target = match.absoluteRow
            }
        }
        let visible = grid.rows.count
        // The command from its prompt, if it fits; otherwise the target a third of the way down.
        let top = target - block.prompt < visible - 1 ? block.prompt - 1 : target - visible / 3
        terminal.scrollTo(row: max(top, 0) - grid.bufferRowOffset)
        guard let scrolled = TerminalGrid(terminal: terminal) else { return true }
        grid = scrolled
        let shown = grid.viewportTop..<(grid.viewportTop + grid.rows.count)
        let marked = rows.clamped(to: shown)
        guard !marked.isEmpty, shown.contains(target) else { return true }
        let first = grid.frame(row: marked.lowerBound - grid.viewportTop, columns: 0..<1)
        let last = grid.frame(row: marked.upperBound - 1 - grid.viewportTop, columns: 0..<1)
        let line = grid.frame(row: target - grid.viewportTop, columns: 0..<grid.columns)
        view.mark(block: view.convert(first.union(last), from: nil), line: view.convert(line, from: nil),
                  color: entry.failed ? preferences.theme.alert : preferences.theme.accent)
        return true
    }

    /// A command's output: all of it while it's still in the scrollback, otherwise what was kept.
    func output(of entry: TimelineEntry) -> String? {
        if let range = liveOutputRange(of: entry), let text = text(of: range) { return text }
        return timeline.value.entry(id: entry.id)?.output?.text ?? entry.output?.text
    }

    // MARK: - Switching branches

    /// Where the prompt ends on the command line's first row, from the 133;B mark zsh draws there.
    private var promptEndColumn: Int?
    private var pressedBranch = false
    private let branchHotspot = BranchHotspot()
    private var branchPopover: NSPopover?
    private var branchPopoverClosed: NSObjectProtocol?

    var isShowingBranchPicker: Bool { branchPopover?.isShown == true }

    /// The branch in the prompt on screen, in window coordinates. Only the prompt counts: not what's
    /// typed after it, nor older prompts, whose directory may be another repository.
    func promptBranchFrame() -> NSRect? {
        guard isAtCommandLine, let branch = session.gitBranch, let grid = TerminalGrid(terminal: terminal) else { return nil }
        let screen = grid.rows.map { ScreenRow(row: $0.absoluteRow, text: $0.text, isWrapped: $0.isWrapped) }
        let top = grid.viewportTop
        let start = CommandBlocks.promptStart(cursorRow: top + grid.cursorVisibleRow, in: screen,
                                              promptLines: session.promptLines) - top
        let commandRow = start + max(session.promptLines - 1, 0)
        guard grid.rows.indices.contains(commandRow) else { return nil }
        for row in max(start, 0)...commandRow {
            var cells = grid.cells(ofRow: row)
            if row == commandRow {
                guard let end = promptEndColumn else { continue }
                cells = cells.filter { $0.column < end }
            }
            guard let range = PromptBranch.range(of: branch, in: cells.map(\.character)) else { continue }
            let first = cells[range.lowerBound], last = cells[range.upperBound - 1]
            return grid.frame(row: row, columns: first.column..<(last.column + last.width))
        }
        return nil
    }

    /// A plain click on the prompt's branch opens the branch picker.
    func pressBranch(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown,
              event.modifierFlags.intersection([.shift, .option, .command, .control]).isEmpty,
              terminal.currentMouseMode == .off,
              let branch = promptBranchFrame(), branch.contains(event.locationInWindow) else { return false }
        pressedBranch = true
        // The first click opened it; the rest of a double-click shouldn't select anything.
        if event.clickCount == 1 { showBranchPicker(at: branch) }
        return true
    }

    /// Opens the branch picker under `anchor` (window coordinates): by default the prompt's branch, or
    /// the cursor when the prompt doesn't show it.
    func showBranchPicker(at anchor: NSRect? = nil) {
        guard session.gitBranch != nil, terminal.window != nil,
              let rect = anchor ?? promptBranchFrame() ?? TerminalGrid(terminal: terminal)?.caret else { return NSSound.beep() }
        branchPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        let picker = BranchPicker(
            repository: GitRepository(directory: URL(fileURLWithPath: session.directory)), theme: preferences.theme,
            onSwitched: { [weak self] in self?.gitBranchDidChange() },
            onDismiss: { [weak popover] in popover?.performClose(nil) })
        let controller = NSHostingController(rootView: picker)
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
        branchPopoverClosed = NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification, object: popover, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.branchPickerDidClose() }
        }
        branchPopover = popover
        popover.show(relativeTo: terminal.convert(rect, from: nil), of: terminal, preferredEdge: .minY)
    }

    private func branchPickerDidClose() {
        if let branchPopoverClosed { NotificationCenter.default.removeObserver(branchPopoverClosed) }
        branchPopoverClosed = nil
        branchPopover = nil
        terminal.window?.makeFirstResponder(terminal)
    }

    /// Shows the pointing hand over the prompt's branch while the mouse is over the terminal.
    private func updateBranchHotspot() {
        guard let window = terminal.window, session.gitBranch != nil,
              terminal.bounds.contains(terminal.convert(window.mouseLocationOutsideOfEventStream, from: nil)) else {
            return branchHotspot.place(at: nil)
        }
        branchHotspot.place(at: promptBranchFrame().map { terminal.convert($0, from: nil) })
    }

    // MARK: - Paths and commands from elsewhere

    /// The running command's full text and where it started, for the history.
    private var runningCommandText: String?
    private var runningDirectory: String?

    /// Puts a command on the command line in place of what's typed, as a paste so nothing in it is
    /// taken as a key, and runs it if asked. Left there, it gets no suggestion after it until it's
    /// edited. False when the shell isn't at its prompt.
    @discardableResult
    func replaceCommandLine(with command: String, run: Bool) -> Bool {
        guard isAtCommandLine else { return false }
        terminal.send(CommandLineEditing.Action.selectAll.sequence)
        terminal.send(txt: "\u{1b}[200~" + command.replacingOccurrences(of: "\u{1b}", with: "") + "\u{1b}[201~")
        terminal.send(run ? [0x0d] : CommandLineEditing.Action.recalled.sequence)
        return true
    }

    /// Types paths for the shell, quoted and separated by spaces: relative to the shell's directory
    /// when they're under it.
    func insertPaths(_ urls: [URL]) {
        guard !urls.isEmpty, session.exitStatus == nil else { return }
        let base = URL(fileURLWithPath: session.directory).standardizedFileURL.path
        let words = urls.map { url -> String in
            let path = url.standardizedFileURL.path
            return ShellQuoting.quote(path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path)
        }
        terminal.send(txt: words.joined(separator: " ") + " ")
    }

    /// Runs `command` at the prompt in place of whatever was typed. False when the shell is busy.
    @discardableResult
    func runAtPrompt(_ command: String) -> Bool {
        guard isAtCommandLine else { return false }
        terminal.send(CommandLineEditing.Action.moveToEnd.sequence + CommandLineEditing.Action.deleteToStart.sequence)
        terminal.send(txt: command + "\r")
        return true
    }

    /// The branch changed outside the shell: update the status bar, and the prompt if it's showing.
    func gitBranchDidChange() {
        refreshGitBranch()
        refreshPrompt()
    }

    /// Has the shell redraw its prompt, keeping what's typed, if it's waiting at one.
    func refreshPrompt() {
        if isAtCommandLine { terminal.send(CommandLineEditing.Action.refreshPrompt.sequence) }
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

    /// The pane's context menu, for a right-click at `point` (window coordinates) when there is one.
    func contextMenu(at point: NSPoint? = nil) -> NSMenu {
        let menu = NSMenu(title: "Pane")
        let selection = terminal.getSelection() ?? ""
        let canPaste = NSPasteboard.general.string(forType: .string) != nil
        let directory = session.directory

        menu.addItem(ClosureMenuItem("Cut", key: "x", image: "scissors", enabled: hasCommandLineSelection) { [weak self] in
            self?.cutCommandLineSelection()
        })
        menu.addItem(ClosureMenuItem("Copy", key: "c", image: "doc.on.doc", enabled: !selection.isEmpty) { [weak self] in
            self?.terminal.copy(self as Any)
        })
        menu.addItem(ClosureMenuItem("Paste", key: "v", image: "doc.on.clipboard", enabled: canPaste) { [weak self] in
            self?.terminal.paste(self as Any)
        })
        menu.addItem(ClosureMenuItem("Select All", key: "a") { [weak self] in
            self?.terminal.selectAll()
        })
        let output = point.flatMap(outputRange(at:)) ?? lastOutputRange
        menu.addItem(ClosureMenuItem("Copy Output", image: "doc.on.doc.fill", enabled: output != nil) { [weak self] in
            if let output { self?.copyOutput(output) }
        })
        menu.addItem(ClosureMenuItem("Select Output", image: "text.line.first.and.arrowtriangle.forward", enabled: output != nil) { [weak self] in
            if let output { self?.selectOutput(output) }
        })
        if preferences.explainFailures, let explainer = environment.explainer,
           let entry = finishedEntry(at: point), FailureReport(entry: entry, output: nil) != nil {
            menu.addItem(ClosureMenuItem("Explain Failure", image: "sparkles", enabled: explainer.availability == .available) { [weak self] in
                guard let self else { return }
                self.host?.explainFailure(of: entry, in: self)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Split Left", key: String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)),
                                     modifiers: [.command, .control], image: "rectangle.lefthalf.inset.filled") { [weak self] in
            guard let self else { return }
            self.host?.split(self, axis: .horizontal, before: true)
        })
        menu.addItem(ClosureMenuItem("Split Right", key: "d", image: "rectangle.righthalf.inset.filled") { [weak self] in
            guard let self else { return }
            self.host?.split(self, axis: .horizontal, before: false)
        })
        menu.addItem(ClosureMenuItem("Split Up", key: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)),
                                     modifiers: [.command, .control], image: "rectangle.tophalf.inset.filled") { [weak self] in
            guard let self else { return }
            self.host?.split(self, axis: .vertical, before: true)
        })
        menu.addItem(ClosureMenuItem("Split Down", key: "d", modifiers: [.command, .shift], image: "rectangle.bottomhalf.inset.filled") { [weak self] in
            guard let self else { return }
            self.host?.split(self, axis: .vertical, before: false)
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
        let clicked = point.map { NSRect(x: $0.x, y: $0.y, width: 1, height: 1) }
        menu.addItem(ClosureMenuItem("Switch Branch…", key: "b", modifiers: [.command, .shift], image: "arrow.triangle.branch",
                                     enabled: session.gitBranch != nil) { [weak self] in
            guard let self else { return }
            self.showBranchPicker(at: self.promptBranchFrame() ?? clicked)
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
        terminal.scrollSensitivity = CGFloat(preferences.scrollSpeed)
        view.apply(theme: theme, scanlines: preferences.scanlines)
        refreshCommandSeparators()
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
        if let end = newestBlockEnd { captureFinishedOutput(end: end) }
        timeline.forgetBlocks()
        terminal.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J")
        terminal.send(txt: "\u{0c}")
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        rowsMayHaveMoved = true
        waitingPromptRow = nil
        view.finder.contentChanged()
        refreshCommandSeparators()
    }

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
        timeline.abandonRunning()
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
