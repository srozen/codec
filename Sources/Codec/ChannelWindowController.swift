import AppKit
import SwiftUI
import SwiftTerm

/// One window (or native tab) running one shell: a codec channel.
final class ChannelWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, LocalProcessTerminalViewDelegate {
    let session: Session
    private(set) var channel: ChannelView!
    var terminal: CodecTerminalView { channel.terminal }
    var onClose: ((ChannelWindowController) -> Void)?

    private let prefs = Preferences.shared
    private let activity = ActivityCounter()
    private var meterTimer: Timer?
    private var ringTimer: Timer?
    private var ticks = 0
    private var fontSize: CGFloat
    /// The Settings font size `fontSize` was last derived from; ⌘+/⌘− zoom is kept relative to it.
    private var baseFontSize: CGFloat
    private var closing = false
    private var preferencesObserver: NSObjectProtocol?

    private static let bandItem = NSToolbarItem.Identifier("codec.band")

    init(directory: String?) {
        session = Session(frequency: FrequencyBand.shared.allocate())
        fontSize = CGFloat(Preferences.shared.fontSize)
        baseFontSize = fontSize

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize(font: Preferences.shared.font())),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.tabbingIdentifier = "codec.channel"
        window.tabbingMode = .automatic
        window.minSize = NSSize(width: 420, height: 240)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unifiedCompact

        super.init(window: window)
        window.delegate = self

        channel = ChannelView(
            session: session,
            onContinue: { [weak self] in self?.reconnect() },
            onExit: { [weak self] in self?.window?.close() })
        window.contentView = channel

        let toolbar = NSToolbar(identifier: "codec.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Self.bandItem]
        window.toolbar = toolbar

        terminal.processDelegate = self
        terminal.bellStyle = .sound
        terminal.onBell = { [weak self] in self?.handleBell() }
        let counter = activity
        terminal.setProcessOutputHandler { counter.tick() }

        applyPreferences()
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: Preferences.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPreferences() }
        }

        session.directory = directory ?? NSHomeDirectory()
        startShell(in: session.directory)
        updateTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
    }

    /// Roughly 100 × 30 cells.
    private static func defaultSize(font: NSFont) -> NSSize {
        let cell = ("W" as NSString).size(withAttributes: [.font: font])
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return NSSize(width: ceil(cell.width * 100) + 30, height: lineHeight * 30 + 50)
    }

    // MARK: - Shell

    private func startShell(in directory: String) {
        let shell = prefs.resolvedShell
        var env = ProcessInfo.processInfo.environment
        for key in ["TERM_SESSION_ID", "ITERM_SESSION_ID", "ITERM_PROFILE", "TMUX", "TMUX_PANE", "__CFBundleIdentifier"] {
            env.removeValue(forKey: key)
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Codec"
        env["TERM_PROGRAM_VERSION"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        env["CODEC_FREQUENCY"] = session.frequency
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }

        session.processName = (shell as NSString).lastPathComponent
        session.connection = prefs.tuningSequence ? .tuning : .live
        terminal.startProcess(
            executable: shell,
            args: [],
            environment: env.map { "\($0.key)=\($0.value)" },
            execName: "-" + (shell as NSString).lastPathComponent,
            currentDirectory: directory)

        startMeter()
        if session.connection == .tuning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) { [weak self] in
                self?.finishTuning()
            }
        }
    }

    private func finishTuning() {
        guard session.connection == .tuning else { return }
        withAnimation(.easeOut(duration: 0.16)) { session.connection = .live }
        channel.playPowerOn()
    }

    private func reconnect() {
        guard case .lost = session.connection else { return }
        channel.overlay.capturesMouse = false
        terminal.feed(text: "\u{1b}[0m\u{1b}[H\u{1b}[2J\u{1b}[3J")
        startShell(in: session.directory.isEmpty ? NSHomeDirectory() : session.directory)
        window?.makeFirstResponder(terminal)
    }

    var hasRunningJob: Bool {
        guard terminal.process.running,
              let pid = ProcessInspector.foregroundProcess(ptyFD: terminal.process.childfd) else { return false }
        return pid != terminal.process.shellPid
    }

    // MARK: - Signal meter & process polling

    private func startMeter() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.meterTick() }
        }
    }

    private func meterTick() {
        let batches = activity.drain()
        let target = batches == 0 ? 0 : min(1, 0.25 + log2(Double(batches) + 1) / 4)
        let next = max(target, session.signal * 0.8)
        let value = next < 0.02 ? 0 : next
        if abs(value - session.signal) > 0.01 || (value == 0 && session.signal != 0) {
            session.signal = value
        }
        ticks += 1
        if ticks % 20 == 0 { pollProcess() }
    }

    private func pollProcess() {
        guard terminal.process.running else { return }
        let shellPid = terminal.process.shellPid
        var name = session.processName
        if let fg = ProcessInspector.foregroundProcess(ptyFD: terminal.process.childfd),
           let fgName = ProcessInspector.name(of: fg) {
            name = fgName
        }
        let directory = ProcessInspector.workingDirectory(of: shellPid) ?? session.directory
        if name != session.processName { session.processName = name }
        if directory != session.directory { session.directory = directory }
        updateTitle()
    }

    private func updateTitle() {
        guard let window else { return }
        let base = session.label.isEmpty ? session.frequency : "\(session.frequency) · \(session.label)"
        let title: String
        if session.incoming {
            title = ringPhase ? "CALL · \(session.frequency)" : "● \(base)"
        } else {
            title = base
        }
        if window.title != title { window.title = title }
        window.representedURL = session.directory.isEmpty ? nil : URL(fileURLWithPath: session.directory)
    }

    // MARK: - Bell

    private func handleBell() {
        let focused = NSApp.isActive && window?.isKeyWindow == true
        if focused {
            if prefs.visualAlert { showAlert() }
            switch prefs.bellSound {
            case .codec: CodecSound.shared.play(.alert)
            case .system: NSSound.beep()
            case .silent: break
            }
        } else {
            switch prefs.bellSound {
            case .codec: CodecSound.shared.play(.call)
            case .system: NSSound.beep()
            case .silent: break
            }
            if prefs.incomingCalls, !session.incoming {
                session.incoming = true
                startRinging()
                IncomingCalls.shared.ring(frequency: session.frequency, label: session.label)
                NSApp.requestUserAttention(.informationalRequest)
                AppDelegate.shared.refreshDockBadge()
            }
        }
    }

    private func showAlert() {
        let caret = terminal.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        if let window, caret != .zero {
            let inWindow = window.convertFromScreen(caret)
            let local = channel.overlay.convert(inWindow, from: nil)
            let y = channel.overlay.isFlipped ? local.minY : channel.overlay.bounds.height - local.maxY
            session.alertAnchor = CGPoint(x: local.midX, y: max(24, y - 6))
        } else {
            session.alertAnchor = CGPoint(x: channel.overlay.bounds.width - 40, y: 40)
        }
        let token = UUID()
        session.alertToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self, self.session.alertToken == token else { return }
            self.session.alertToken = nil
        }
    }

    private var ringPhase = false

    private func startRinging() {
        ringTimer?.invalidate()
        ringTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.ringPhase.toggle()
                self.updateTitle()
            }
        }
    }

    private func answerCall() {
        guard session.incoming else { return }
        session.incoming = false
        ringTimer?.invalidate()
        ringTimer = nil
        ringPhase = false
        IncomingCalls.shared.hangUp(frequency: session.frequency)
        updateTitle()
        AppDelegate.shared.refreshDockBadge()
    }

    // MARK: - Preferences

    func applyPreferences() {
        let theme = prefs.theme
        window?.appearance = theme.appearance
        if CGFloat(prefs.fontSize) != baseFontSize {
            fontSize = max(7, fontSize + CGFloat(prefs.fontSize) - baseFontSize)
            baseFontSize = CGFloat(prefs.fontSize)
        }
        let font = prefs.font(size: fontSize)
        if terminal.font != font { terminal.font = font }
        terminal.nativeForegroundColor = theme.foreground
        terminal.nativeBackgroundColor = theme.background
        terminal.backgroundOpacity = 0
        terminal.caretColor = theme.accent
        terminal.caretTextColor = theme.background
        terminal.selectedTextBackgroundColor = theme.selection
        terminal.installColors(theme.terminalPalette)
        terminal.optionAsMetaKey = prefs.optionAsMeta
        channel.apply(theme: theme, opacity: prefs.opacity, blur: prefs.blur, scanlinesOn: prefs.scanlines)
    }

    @objc func biggerFont(_ sender: Any?) {
        fontSize = min(72, fontSize + 1)
        applyPreferences()
    }

    @objc func smallerFont(_ sender: Any?) {
        fontSize = max(7, fontSize - 1)
        applyPreferences()
    }

    @objc func resetFontSize(_ sender: Any?) {
        fontSize = CGFloat(prefs.fontSize)
        applyPreferences()
    }

    @objc func clearBuffer(_ sender: Any?) {
        terminal.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J")
        terminal.send(txt: "\u{0c}")
    }

    override func newWindowForTab(_ sender: Any?) {
        AppDelegate.shared.newTab(sender)
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let url = URL(string: directory), url.isFileURL else { return }
        session.directory = url.path
        updateTitle()
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard !closing else { return }
        meterTimer?.invalidate()
        session.signal = 0

        let clean = exitCode.map { $0 < 128 } ?? false
        switch prefs.exitBehavior {
        case .alwaysClose:
            window?.close()
            return
        case .closeIfClean where clean:
            window?.close()
            return
        default:
            break
        }
        loseSignal(exitCode: exitCode)
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        meterTimer?.invalidate()
        loseSignal(exitCode: nil)
    }

    private func loseSignal(exitCode: Int32?) {
        withAnimation(.easeOut(duration: 0.25)) { session.connection = .lost(exitCode: exitCode) }
        channel.overlay.capturesMouse = true
        window?.makeFirstResponder(channel.keyCatcher)
        if prefs.bellSound == .codec { CodecSound.shared.play(.lost) }
        updateTitle()
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        answerCall()
        if case .lost = session.connection {
            window?.makeFirstResponder(channel.keyCatcher)
        } else {
            window?.makeFirstResponder(terminal)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasRunningJob, let window else { return true }
        let alert = NSAlert()
        alert.messageText = "End this transmission?"
        alert.informativeText = "“\(session.processName)” is still running on \(session.frequency). Closing the channel will terminate it."
        alert.addButton(withTitle: "Terminate")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                window.close()
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        closing = true
        meterTimer?.invalidate()
        ringTimer?.invalidate()
        if terminal.process.running { terminal.terminate() }
        IncomingCalls.shared.hangUp(frequency: session.frequency)
        FrequencyBand.shared.release(session.frequency)
        onClose?(self)
    }

    // MARK: - NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.bandItem, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.bandItem, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.bandItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        let host = NSHostingView(rootView: CodecBand(session: session))
        host.sizingOptions = [.intrinsicContentSize]
        item.view = host
        item.label = "Channel"
        item.visibilityPriority = .high
        return item
    }
}
