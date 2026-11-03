import Testing
import AppKit
import CodecCore
@testable import CodecUI

/// Selection through the real terminal view, as the mouse drives it.
@Suite("Selection", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct SelectionTests {
    private func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
                           pressure: type == .leftMouseUp ? 0 : 1)!
    }

    private func doubleClick(_ terminal: CodecTerminalView, at point: NSPoint, in window: NSWindow) {
        for clicks in 1...2 {
            terminal.mouseDown(with: event(.leftMouseDown, at: point, in: window, clicks: clicks))
            terminal.mouseUp(with: event(.leftMouseUp, at: point, in: window, clicks: clicks))
        }
    }

    /// A pane showing `text`, run by `cat` so nothing else writes to the screen.
    private func paneShowing(_ text: String, env: TestEnvironment) async throws -> (Pane, NSWindow) {
        env.preferences.shellPath = "/bin/cat"
        let pane = env.makePane(host: FakeHost())
        let window = makeTestWindow(size: NSSize(width: 800, height: 400))
        window.contentView = pane.view
        pane.view.layoutSubtreeIfNeeded()
        pane.terminal.feed(text: text)
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        #expect(await waitUntil { pane.terminal.visibleRowsText(0..<10).joined().contains(firstLine) })
        return (pane, window)
    }

    private func point(of target: String, in pane: Pane, offset: Int = 1) throws -> NSPoint {
        let grid = try #require(TerminalGrid(terminal: pane.terminal))
        for (row, snapshot) in grid.rows.enumerated() {
            if let range = snapshot.text.range(of: target) {
                let column = snapshot.text.distance(from: snapshot.text.startIndex, to: range.lowerBound) + offset
                return grid.center(row: row, column: column)
            }
        }
        Issue.record("\(target) isn't on screen")
        return .zero
    }

    @Test(arguments: [
        ("contact jane.doe@example.com today", "doe", "jane.doe@example.com"),
        ("listening on 192.168.1.20:8080 now", "168", "192.168.1.20:8080"),
        ("Sources/App/Main.swift:42:7: error", "Main", "Sources/App/Main.swift:42:7"),
    ])
    func doubleClickSelectsTheWholeToken(line: String, target: String, expected: String) async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let (pane, window) = try await paneShowing(line + "\r\n", env: env)
        defer { pane.shutDown(); window.close() }
        doubleClick(pane.terminal, at: try point(of: target, in: pane), in: window)
        #expect(pane.terminal.getSelection() == expected)
    }

    @Test func copyOnSelectCopiesWhatsSelected() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        env.preferences.copyOnSelect = true
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer { pasteboard.clearContents(); if let saved { pasteboard.setString(saved, forType: .string) } }
        let (pane, window) = try await paneShowing("visit https://swift.org/blog today\r\n", env: env)
        defer { pane.shutDown(); window.close() }
        doubleClick(pane.terminal, at: try point(of: "swift.org", in: pane), in: window)
        #expect(pasteboard.string(forType: .string) == "https://swift.org/blog")
    }
}

/// zsh with Codec's integration in a window: command output and the command line.
@Suite("Selection with zsh", .serialized, .timeLimit(.minutes(1)),
       .enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")))
@MainActor
struct ZshSelectionTests {
    private func zshPane(_ env: TestEnvironment, prompt: String = "%# ", directory: String? = nil) throws -> (Pane, NSWindow) {
        let config = env.directory.appendingPathComponent("zdotdir")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "PS1='\(prompt)'\n".write(to: config.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        setenv("ZDOTDIR", config.path, 1)
        defer { unsetenv("ZDOTDIR") }
        let pane = env.makePane(directory: directory, host: FakeHost())
        let window = makeTestWindow(size: NSSize(width: 800, height: 400))
        window.contentView = pane.view
        pane.view.layoutSubtreeIfNeeded()
        return (pane, window)
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                           pressure: type == .leftMouseUp ? 0 : 1)!
    }

    @Test func copiesAndSelectsACommandsOutput() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let (pane, window) = try zshPane(env)
        defer { pane.shutDown(); window.close() }
        #expect(await waitUntil { pane.isAtCommandLine })
        pane.terminal.send(txt: "printf 'one\\ntwo  \\nthree\\n'\r")
        #expect(await waitUntil { pane.lastOutputRange != nil && pane.isAtCommandLine })
        let output = try #require(pane.lastOutputRange)
        #expect(pane.text(of: output) == "one\ntwo\nthree")

        pane.selectOutput(output)
        let selected = try #require(pane.terminal.getSelection())
        #expect(selected.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) } == ["one", "two", "three"])
    }

    /// Dragging on the command line selects through zsh only: no second, terminal highlight.
    @Test func draggingOnTheCommandLineSelectsInTheShell() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let (pane, window) = try zshPane(env)
        defer { pane.shutDown(); window.close() }
        #expect(await waitUntil { pane.isAtCommandLine })
        pane.terminal.send(txt: "echo hello world")
        #expect(await waitUntil { pane.terminal.visibleRowsText(0..<5).joined().contains("echo hello world") })

        let grid = try #require(TerminalGrid(terminal: pane.terminal))
        let start = NSPoint(x: grid.caret.minX - 5 * grid.caret.width, y: grid.caret.midY)
        let end = NSPoint(x: grid.caret.minX, y: grid.caret.midY)
        pane.terminal.mouseDown(with: event(.leftMouseDown, at: start, in: window))
        pane.terminal.mouseDragged(with: event(.leftMouseDragged, at: end, in: window))
        pane.terminal.mouseUp(with: event(.leftMouseUp, at: end, in: window))
        #expect(await waitUntil { pane.session.commandLineSelection })
        #expect(!pane.terminal.selectionActive)

        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer { pasteboard.clearContents(); if let saved { pasteboard.setString(saved, forType: .string) } }
        pasteboard.clearContents()
        pane.terminal.copy(self)
        #expect(await waitUntil { pasteboard.string(forType: .string) == "world" })

        pane.terminal.send([0x7F, 0x0D])
        #expect(await waitUntil { pane.session.lastCommand != nil })
        #expect(pane.session.lastCommand?.command == "echo hello ")
    }
}

/// ⌘-click on a file's name in the output opens it.
@Suite("Opening listed files", .serialized, .timeLimit(.minutes(1)),
       .enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")))
@MainActor
struct OpenListedFileTests {
    private func zshPane(_ env: TestEnvironment, host: FakeHost, directory: String) throws -> (Pane, NSWindow) {
        let config = env.directory.appendingPathComponent("zdotdir")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "PS1='%# '\n".write(to: config.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        setenv("ZDOTDIR", config.path, 1)
        defer { unsetenv("ZDOTDIR") }
        let pane = env.makePane(directory: directory, host: host)
        let window = makeTestWindow(size: NSSize(width: 800, height: 400))
        window.contentView = pane.view
        pane.view.layoutSubtreeIfNeeded()
        return (pane, window)
    }

    private func click(_ pane: Pane, at point: NSPoint, in window: NSWindow, modifiers: NSEvent.ModifierFlags) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            if type == .leftMouseDown { pane.terminal.mouseDown(with: event) } else { pane.terminal.mouseUp(with: event) }
        }
    }

    /// The center of the last cell showing `target` on screen, which is output rather than the command typed.
    private func point(of target: String, in pane: Pane) throws -> NSPoint {
        let grid = try #require(TerminalGrid(terminal: pane.terminal))
        for (row, snapshot) in grid.rows.enumerated().reversed() {
            if let range = snapshot.text.range(of: target, options: .backwards) {
                return grid.center(row: row, column: snapshot.text.distance(from: snapshot.text.startIndex, to: range.lowerBound))
            }
        }
        Issue.record("\(target) isn't on screen")
        return .zero
    }

    @Test func commandClickOpensAFileListedFromAFolderTheCommandWasGiven() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let project = env.directory.appendingPathComponent("project")
        let sources = project.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "".write(to: sources.appendingPathComponent("listed.swift"), atomically: true, encoding: .utf8)
        let host = FakeHost()
        let (pane, window) = try zshPane(env, host: host, directory: project.path)
        defer { pane.shutDown(); window.close() }
        #expect(await waitUntil { pane.isAtCommandLine })
        pane.terminal.send(txt: "ls Sources; echo done-listing\r")
        #expect(await waitUntil { pane.lastOutputRange != nil && pane.isAtCommandLine })
        #expect(await waitUntil { pane.terminal.visibleRowsText(0..<10).joined().contains("done-listing") })

        let name = try point(of: "listed.swift", in: pane)
        // A plain click selects as usual; it takes ⌘ to open.
        click(pane, at: name, in: window, modifiers: [])
        #expect(host.openedFiles.isEmpty)
        click(pane, at: name, in: window, modifiers: .command)
        #expect(host.openedFiles.map { $0.resolvingSymlinksInPath().path }
                == [sources.appendingPathComponent("listed.swift").resolvingSymlinksInPath().path])

        // A word that names no file is left to the terminal.
        click(pane, at: try point(of: "done-listing", in: pane), in: window, modifiers: .command)
        #expect(host.openedFiles.count == 1)
    }
}

extension OpenListedFileTests {
    @Test func holdingCommandOverAFileUnderlinesIt() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let project = env.directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "".write(to: project.appendingPathComponent("hovered.txt"), atomically: true, encoding: .utf8)
        try "".write(to: project.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        let host = FakeHost()
        let (pane, window) = try zshPane(env, host: host, directory: project.path)
        defer { pane.shutDown(); window.close() }
        #expect(await waitUntil { pane.isAtCommandLine })
        pane.terminal.send(txt: "ls; echo done-listing\r")
        #expect(await waitUntil { pane.lastOutputRange != nil && pane.isAtCommandLine })
        #expect(await waitUntil { pane.terminal.visibleRowsText(0..<10).joined().contains("done-listing") })

        let name = try point(of: "hovered.txt", in: pane)
        let link = pane.view.fileLink
        pane.updateFileLink(at: name, modifiers: [])
        #expect(link.frames.isEmpty)

        pane.updateFileLink(at: name, modifiers: .command)
        let grid = try #require(TerminalGrid(terminal: pane.terminal))
        let cell = grid.cell(at: name)
        #expect(link.frames == [link.convert(grid.frame(row: cell.row, columns: cell.column..<(cell.column + 11)), from: nil)])
        #expect(link.fileTag != nil)
        // The other file is marked too, less.
        let other = grid.cell(at: try point(of: "other.txt", in: pane))
        #expect(link.marks == [link.convert(grid.frame(row: other.row, columns: other.column..<(other.column + 9)), from: nil)])

        // Moving onto a word that isn't a file leaves both marked, neither under the pointer; letting
        // go of ⌘ takes every mark away.
        pane.updateFileLink(at: try point(of: "done-listing", in: pane), modifiers: .command)
        #expect(link.frames.isEmpty)
        #expect(link.marks.count == 2)
        #expect(link.fileTag == nil)
        pane.updateFileLink(at: name, modifiers: .command)
        #expect(!link.frames.isEmpty)
        pane.updateFileLink(at: name, modifiers: [])
        #expect(link.frames.isEmpty)
        #expect(link.marks.isEmpty)
    }

    /// Regression: the prompt's own lines were left out, found from command blocks. After a rewrap a
    /// block is found again from the newest line ending with its command, which can be its own output
    /// (`wildcat list` for `cat list`), so a line of output went unmarked.
    @Test func everyNameIsMarkedAfterBlocksMove() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let project = env.directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "first.txt\nwildcat list\n".write(to: project.appendingPathComponent("list"), atomically: true, encoding: .utf8)
        try "".write(to: project.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
        let config = env.directory.appendingPathComponent("zdotdir")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "PS1=$'top\\n\\n%# '\n".write(to: config.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        setenv("ZDOTDIR", config.path, 1)
        let host = FakeHost()
        let pane = env.makePane(directory: project.path, host: host)
        unsetenv("ZDOTDIR")
        let window = makeTestWindow(size: NSSize(width: 800, height: 400))
        window.contentView = pane.view
        pane.view.layoutSubtreeIfNeeded()
        defer { pane.shutDown(); window.close() }
        #expect(await waitUntil { pane.isAtCommandLine && pane.session.promptLines == 3 })
        pane.terminal.send(txt: "cat list\r")
        #expect(await waitUntil { pane.lastOutputRange != nil && pane.isAtCommandLine })
        #expect(await waitUntil { pane.terminal.visibleRowsText(0..<12).joined().contains("wildcat list") })

        // As a resize would.
        pane.sizeChanged(source: pane.terminal, newCols: 80, newRows: 24)
        pane.updateFileLink(at: try point(of: "wildcat", in: pane), modifiers: .command)
        let grid = try #require(TerminalGrid(terminal: pane.terminal))
        let first = grid.cell(at: try point(of: "first.txt", in: pane))
        #expect(pane.view.fileLink.marks.contains(pane.view.fileLink.convert(
            grid.frame(row: first.row, columns: first.column..<(first.column + 9)), from: nil)))
    }

    private func modifiersChanged(to flags: NSEvent.ModifierFlags, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                         characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55)!
    }

    /// The line comes with ⌘ going down, without the pointer moving, and goes with ⌘ coming up,
    /// wherever that happens.
    @Test func theLineLastsAsLongAsCommandIsDown() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let project = env.directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "".write(to: project.appendingPathComponent("pressed.txt"), atomically: true, encoding: .utf8)
        let host = FakeHost()
        let (pane, window) = try zshPane(env, host: host, directory: project.path)
        let other = makeTestWindow()
        defer { pane.shutDown(); window.close(); other.close() }
        #expect(await waitUntil { pane.isAtCommandLine })
        pane.terminal.send(txt: "ls; echo done-listing\r")
        #expect(await waitUntil { pane.lastOutputRange != nil && pane.isAtCommandLine })
        #expect(await waitUntil { pane.terminal.visibleRowsText(0..<10).joined().contains("done-listing") })
        let name = try point(of: "pressed.txt", in: pane)
        pane.pointerLocation = { name }
        let link = pane.view.fileLink

        NSApp.sendEvent(modifiersChanged(to: .command, in: window))
        #expect(!link.frames.isEmpty)
        NSApp.sendEvent(modifiersChanged(to: [], in: window))
        #expect(link.frames.isEmpty)

        // Let go in another window.
        NSApp.sendEvent(modifiersChanged(to: .command, in: window))
        #expect(!link.frames.isEmpty)
        NSApp.sendEvent(modifiersChanged(to: [], in: other))
        #expect(link.frames.isEmpty)

        // Let go in another app, after Codec stopped being the active one.
        NSApp.sendEvent(modifiersChanged(to: .command, in: window))
        #expect(!link.frames.isEmpty)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        #expect(link.frames.isEmpty)
    }
}

/// The branch in the prompt opens the branch picker.
@Suite("Branch in the prompt", .serialized, .timeLimit(.minutes(1)),
       .enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")))
@MainActor
struct PromptBranchClickTests {
    private func repository(in env: TestEnvironment, branch: String) throws -> String {
        let git = env.directory.appendingPathComponent("repo/.git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "ref: refs/heads/\(branch)\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        return git.deletingLastPathComponent().path
    }

    private func zshPane(_ env: TestEnvironment, prompt: String, directory: String) throws -> (Pane, NSWindow) {
        let config = env.directory.appendingPathComponent("zdotdir")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "PS1='\(prompt)'\n".write(to: config.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        setenv("ZDOTDIR", config.path, 1)
        defer { unsetenv("ZDOTDIR") }
        let pane = env.makePane(directory: directory, host: FakeHost())
        let window = makeTestWindow(size: NSSize(width: 800, height: 400))
        window.contentView = pane.view
        pane.view.layoutSubtreeIfNeeded()
        return (pane, window)
    }

    private func click(_ pane: Pane, at point: NSPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                           pressure: type == .leftMouseUp ? 0 : 1)!
            if type == .leftMouseDown { pane.terminal.mouseDown(with: event) } else { pane.terminal.mouseUp(with: event) }
        }
    }

    @Test func clickingTheBranchOpensThePicker() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let (pane, window) = try zshPane(env, prompt: "[topic] %# ", directory: try repository(in: env, branch: "topic"))
        defer { pane.shutDown(); window.close() }
        #expect(await waitUntil { pane.isAtCommandLine && pane.promptBranchFrame() != nil })
        // What's typed doesn't count, even when it's the branch's name.
        pane.terminal.send(txt: "echo topic")
        #expect(await waitUntil { pane.terminal.visibleRowsText(0..<5).joined().contains("echo topic") })

        let frame = try #require(pane.promptBranchFrame())
        let grid = try #require(TerminalGrid(terminal: pane.terminal))
        #expect(frame == grid.frame(row: grid.cursorVisibleRow, columns: 1..<6))
        #expect(!pane.terminal.selectionActive)

        // A popover only shows from a window that's on screen.
        window.orderBack(nil)
        click(pane, at: NSPoint(x: frame.midX, y: frame.midY), in: window)
        #expect(await waitUntil { pane.isShowingBranchPicker })
        #expect(!pane.terminal.selectionActive)
        #expect(!pane.session.commandLineSelection)
    }

    @Test func onlyThePromptCounts() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let (pane, window) = try zshPane(env, prompt: "%# ", directory: try repository(in: env, branch: "topic"))
        defer { pane.shutDown(); window.close() }
        #expect(await waitUntil { pane.isAtCommandLine })
        pane.terminal.send(txt: "echo topic")
        #expect(await waitUntil { pane.terminal.visibleRowsText(0..<5).joined().contains("echo topic") })
        #expect(pane.promptBranchFrame() == nil)
    }
}

/// Answers git calls from a script.
private final class FakeGit: GitRunning, @unchecked Sendable {
    var listing = "refs/heads/main\0*\0" + "2 hours ago\nrefs/heads/feature\0 \0" + "3 days ago\nrefs/remotes/origin/fix\0 \0" + "a week ago\n"
    var switchFails: String?
    private(set) var calls: [[String]] = []

    func run(_ arguments: [String], in directory: URL) async throws -> (status: Int32, output: String, errors: String) {
        calls.append(arguments)
        switch arguments.first {
        case "for-each-ref": return (0, listing, "")
        case "switch": return switchFails.map { (1, "", $0) } ?? (0, "", "")
        case "check-ref-format": return (arguments.last?.contains(" ") == true ? 1 : 0, "", "")
        default: return (0, "", "")
        }
    }
}

@Suite("Branch switcher")
@MainActor
struct BranchSwitcherTests {
    @Test func loadsAndFiltersBranches() async {
        let git = FakeGit()
        let switcher = BranchSwitcher(repository: GitRepository(directory: URL(fileURLWithPath: "/tmp"), runner: git))
        await switcher.load()
        #expect(switcher.state == .ready)
        #expect(switcher.branches.map(\.name) == ["main", "feature", "origin/fix"])
        #expect(switcher.matches("").count == 3)
        #expect(switcher.matches("fix").map(\.name) == ["origin/fix"])
    }

    @Test func switchesAndReportsFailures() async {
        let git = FakeGit()
        let switcher = BranchSwitcher(repository: GitRepository(directory: URL(fileURLWithPath: "/tmp"), runner: git))
        await switcher.load()
        let feature = switcher.branches[1]
        #expect(await switcher.switchTo(feature))
        #expect(git.calls.last == ["switch", "feature"])

        git.switchFails = "error: Your local changes would be overwritten by checkout"
        #expect(await !switcher.switchTo(feature))
        #expect(switcher.state == .failed("error: Your local changes would be overwritten by checkout"))
    }

    @Test func createsBranchesWithValidNamesOnly() async {
        let git = FakeGit()
        let switcher = BranchSwitcher(repository: GitRepository(directory: URL(fileURLWithPath: "/tmp"), runner: git))
        #expect(await switcher.createBranch("feature/new"))
        #expect(git.calls.last == ["switch", "-c", "feature/new"])
        #expect(await !switcher.createBranch("bad name"))
        if case .failed(let message) = switcher.state { #expect(message.contains("isn’t a valid branch name")) } else { Issue.record("expected a failure") }
    }

    @Test func refreshesTheBranchAfterASwitch() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let repo = env.directory.appendingPathComponent("repo/.git")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: repo.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let pane = env.makePane(directory: repo.deletingLastPathComponent().path)
        defer { pane.shutDown() }
        #expect(pane.session.gitBranch == "main")
        try "ref: refs/heads/other\n".write(to: repo.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        pane.gitBranchDidChange()
        #expect(pane.session.gitBranch == "other")
    }
}
