import AppKit
import SwiftTerm
import SwiftUI
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
    /// The shell asked for the history (↑ or ⌃R at the prompt), starting from what's typed.
    func showHistory(for pane: Pane, request: IntegrationEvent.HistoryRequest, typed: String)
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
        terminal.contextMenuProvider = { [weak self] event in self?.contextMenu(at: event.locationInWindow) }
        terminal.shouldOwnPress = { [weak self] event in
            guard let self else { return false }
            return self.pressBranch(event) || self.beginCommandLineGesture(event)
        }
        terminal.onOwnedDrag = { [weak self] event in self?.continueCommandLineGesture(event) }
        terminal.onOwnedRelease = { [weak self] _ in
            guard let self else { return }
            if self.pressedBranch { self.pressedBranch = false } else { self.endCommandLineGesture() }
        }
        terminal.addSubview(branchHotspot)
        terminal.onDropFiles = { [weak self] urls in self?.insertPaths(urls) }
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
                // The prompt ends here; what follows on this row is the command line.
                let column = event.cursor.col
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.promptEndColumn = column }
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
        let theme = preferences.theme
        env["CODEC_SELECTION_STYLE"] = "bg=" + theme.selection.hexString
        env["CODEC_SUGGESTIONS"] = preferences.suggestCommands ? "1" : "0"
        env["CODEC_HISTORY_KEYS"] = preferences.historyKeys ? "1" : "0"
        env["CODEC_COMPLETION"] = preferences.friendlyCompletion ? "1" : "0"
        // Suggestions in the theme's muted color; the completion menu's pick in its selection color.
        env["CODEC_SUGGESTION_STYLE"] = "fg=" + (theme.background.blended(withFraction: 0.45, of: theme.foreground) ?? theme.foreground).hexString
        env["CODEC_MENU_SELECTION"] = theme.selection.sgrBackground
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
        branchPopover?.close()
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
            return
        case .historyFile(let path):
            environment.history.useShellFile(URL(fileURLWithPath: path))
            return
        case .historyRequest(let request, let typed):
            host?.showHistory(for: self, request: request, typed: typed)
            return
        case .commandStarted:
            runningCommandText = nil
            runningDirectory = session.directory
        default:
            break
        }
        let command = session.running?.command ?? ""
        let started = session.running?.started
        session.apply(event)
        if case .commandStarted(let started) = event, let screen = pendingCommandScreen {
            pendingCommandScreen = nil
            if let block = CommandBlocks.locate(command: started, in: screen.rows, cursorRow: screen.cursorRow,
                                                promptLines: session.promptLines) {
                blocks.record(block)
            }
        }
        guard case .commandFinished(let exitCode, let duration) = event else { return }
        if preferences.recordHistory {
            environment.history.record(HistoryEntry(
                command: runningCommandText ?? command, date: started ?? Date().addingTimeInterval(-duration),
                directory: runningDirectory ?? session.directory, exitCode: exitCode, duration: duration))
        }
        runningCommandText = nil
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
        guard let grid = TerminalGrid(terminal: terminal) else { return }
        let cell = grid.cell(at: point)
        guard let line = grid.logicalLine(containing: cell.row),
              let index = line.cells.firstIndex(where: { $0.row == cell.row && $0.column == cell.column }),
              let range = SmartSelection.range(in: line.characters, at: index) else { return }
        let token = String(line.characters[range])
        guard terminal.getSelection() != token else { return }
        let first = line.cells[range.lowerBound], last = line.cells[range.upperBound - 1]
        terminal.selectByDragging(from: grid.center(row: first.row, column: first.column),
                                  to: grid.trailingEdge(row: last.row, column: last.column))
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
        guard let grid = TerminalGrid(terminal: terminal), let end = newestBlockEnd,
              let index = blocks.index(containing: grid.viewportTop + grid.cell(at: point).row) else { return nil }
        return blocks.outputRange(of: index, end: end)
    }

    /// The output of the most recent command that has finished.
    var lastOutputRange: Range<Int>? {
        guard let last = blocks.blocks.indices.last, let end = newestBlockEnd else { return nil }
        let index = session.running == nil ? last : last - 1
        return blocks.outputRange(of: index, end: end)
    }

    /// The text of some rows, with soft-wrapped lines rejoined and trailing blank space removed.
    func text(of range: Range<Int>) -> String? {
        guard let snapshot = terminal.terminalContentSnapshot(
            region: .history(maximumScrollbackRows: CodecTerminalView.scrollback)) else { return nil }
        var lines: [String] = []
        for row in snapshot.rows where range.contains(row.absoluteRow) {
            let text = row.text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            if row.isWrapped, !lines.isEmpty { lines[lines.count - 1] += text } else { lines.append(text) }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
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
    /// taken as a key, and runs it if asked. False when the shell isn't at its prompt.
    @discardableResult
    func replaceCommandLine(with command: String, run: Bool) -> Bool {
        guard isAtCommandLine else { return false }
        terminal.send(CommandLineEditing.Action.selectAll.sequence)
        terminal.send(txt: "\u{1b}[200~" + command.replacingOccurrences(of: "\u{1b}", with: "") + "\u{1b}[201~" + (run ? "\r" : ""))
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
