import Testing
import Foundation
import AppKit
import CodecCore
@testable import CodecUI

/// The Commands sidebar and going back to earlier commands, with a real zsh.
@Suite("Commands timeline", .serialized, .timeLimit(.minutes(1)),
       .enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")))
@MainActor
struct TimelineTests {
    private func useCleanZsh(_ env: TestEnvironment) throws {
        let config = env.directory.appendingPathComponent("zdotdir")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "PS1='%# '\n".write(to: config.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        setenv("ZDOTDIR", config.path, 1)
    }

    private func zshPane(_ env: TestEnvironment) throws -> (Pane, NSWindow) {
        try useCleanZsh(env)
        defer { unsetenv("ZDOTDIR") }
        let pane = env.makePane(host: FakeHost())
        let window = makeTestWindow(size: NSSize(width: 800, height: 300))
        window.contentView = pane.view
        pane.view.layoutSubtreeIfNeeded()
        return (pane, window)
    }

    private func run(_ command: String, in pane: Pane) async -> Bool {
        let count = pane.timeline.entries.count
        pane.terminal.send(txt: command + "\r")
        return await waitUntil { pane.timeline.entries.count == count + 1 && pane.timeline.running == nil && pane.isAtCommandLine }
    }

    @Test func recordsEachCommandWithItsOutput() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        try FileManager.default.createDirectory(at: env.directory.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let (pane, window) = try zshPane(env)
        defer { pane.shutDown(); window.close() }
        #expect(await waitUntil { pane.isAtCommandLine })

        #expect(await run("printf 'alpha\\nbeta\\n'", in: pane))
        #expect(await run("cd sub && false", in: pane))
        #expect(await run("seq 1 40", in: pane))
        // Its output is kept once the next prompt is drawn, which can come after the command is reported finished.
        #expect(await waitUntil { pane.timeline.entries.last?.output != nil })

        let entries = pane.timeline.entries
        #expect(entries.map(\.command) == ["printf 'alpha\\nbeta\\n'", "cd sub && false", "seq 1 40"])
        #expect(entries.map(\.status) == [.succeeded, .failed(1), .succeeded])
        #expect(entries[0].output?.text == "alpha\nbeta")
        #expect(entries[1].output == nil)
        #expect(entries[2].output?.lineCount == 40)
        #expect(entries[2].output?.summary == "40")
        #expect(entries[2].directory.hasSuffix("/sub"))
        #expect(!entries[1].directory.hasSuffix("/sub"))
    }

    /// Typed ahead (a paste, a script), the next command can be on screen before the prompt's mark
    /// reaches the main thread; what the command before printed still stops at the prompt after it.
    @Test func keepsOutputApartFromACommandTypedAhead() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let (pane, window) = try zshPane(env)
        defer { pane.shutDown(); window.close() }
        #expect(await waitUntil { pane.isAtCommandLine })
        pane.terminal.send(txt: "printf 'one\\ntwo\\n'\rseq 1 3\r")
        // Holds the main thread while zsh runs both, so the marks are handled after the screen moved on.
        usleep(1_500_000)
        #expect(await waitUntil { pane.timeline.entries.count == 2 && pane.timeline.entries.last?.output != nil })
        #expect(pane.timeline.entries.map(\.command) == ["printf 'one\\ntwo\\n'", "seq 1 3"])
        #expect(pane.timeline.entries.first?.output?.text == "one\ntwo")
        #expect(pane.timeline.entries.last?.output?.text == "1\n2\n3")
    }

    /// The first command has scrolled off screen; going back to it scrolls up and marks it.
    @Test func goesBackToACommandInTheScrollback() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let (pane, window) = try zshPane(env)
        defer { pane.shutDown(); window.close() }
        #expect(await waitUntil { pane.isAtCommandLine })
        #expect(await run("echo first-command", in: pane))
        #expect(await run("seq 1 80", in: pane))

        let first = try #require(pane.timeline.entries.first)
        let block = try #require(first.block)
        let before = try #require(TerminalGrid(terminal: pane.terminal))
        #expect(before.viewportTop > block.prompt)

        #expect(pane.reveal(first) != nil)
        let after = try #require(TerminalGrid(terminal: pane.terminal))
        #expect((after.viewportTop..<(after.viewportTop + after.rows.count)).contains(block.prompt))
        #expect(pane.view.commandMark.isShowing)
        #expect(pane.output(of: first) == "first-command")

        // With a query, it goes to the line of the output that holds it.
        let seq = pane.timeline.entries[1]
        let row = try #require(pane.reveal(seq, matching: TextSearch.expression(for: "77", options: FindOptions())))
        let atMatch = try #require(TerminalGrid(terminal: pane.terminal))
        #expect(atMatch.rows.first { $0.absoluteRow == row }?.text.trimmingCharacters(in: .whitespaces) == "77")
        #expect(atMatch.rows.contains { $0.text.trimmingCharacters(in: .whitespaces) == "77" })
    }

    /// Narrowing the terminal rewraps its lines, which moves every row: commands are found again.
    @Test func findsCommandsAgainAfterAResize() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let (pane, window) = try zshPane(env)
        defer { pane.shutDown(); window.close() }
        #expect(await waitUntil { pane.isAtCommandLine })
        #expect(await run("echo a-fairly-long-line-of-output-that-will-wrap-once-the-pane-gets-narrower-than-it-is", in: pane))
        #expect(await run("echo second", in: pane))
        let before = try #require(pane.timeline.entries[1].block)

        window.setContentSize(NSSize(width: 300, height: 300))
        pane.view.layoutSubtreeIfNeeded()
        #expect(await waitUntil { pane.terminal.terminalInputStateSnapshot()?.dimensions.cols ?? 99 < 40 })

        let second = pane.timeline.entries[1]
        let rows = try #require(pane.rows(of: second))
        #expect(pane.timeline.entries[1].block != before)
        #expect(pane.text(of: rows.dropFirst(rows.count - 1)) == "second")
        #expect(pane.output(of: pane.timeline.entries[0])?.hasPrefix("a-fairly-long") == true)
        #expect(pane.lastOutputRange.flatMap(pane.text(of:)) == "second")
        #expect(pane.reveal(pane.timeline.entries[0]) != nil)

        // Running the same command again after another resize doesn't take the earlier one's place.
        window.setContentSize(NSSize(width: 500, height: 300))
        pane.view.layoutSubtreeIfNeeded()
        #expect(await waitUntil { pane.terminal.terminalInputStateSnapshot()?.dimensions.cols ?? 0 > 40 })
        #expect(await run("echo second", in: pane))
        let blocks = pane.timeline.entries.compactMap(\.block)
        #expect(blocks.count == 3)
        #expect(blocks.map(\.prompt) == blocks.map(\.prompt).sorted() && Set(blocks.map(\.prompt)).count == 3)
        #expect(pane.output(of: pane.timeline.entries[1]) == "second")
    }

    /// With an older command selected in the sidebar, running a new one from the terminal stays at the new one.
    @Test func runningACommandDoesntGoBackToTheSelectedOne() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        try useCleanZsh(env)
        let controller = TerminalWindowController(directory: env.directory.path, environment: env.environment)
        unsetenv("ZDOTDIR")
        controller.window?.setContentSize(NSSize(width: 1100, height: 400))
        controller.window?.layoutIfNeeded()
        defer {
            controller.model.tabs.flatMap(\.panes).forEach { $0.shutDown() }
            controller.window?.close()
        }
        let pane = try #require(controller.model.selected?.focused)
        #expect(await waitUntil { pane.isAtCommandLine })
        #expect(await run("echo first", in: pane))
        #expect(await run("seq 1 60", in: pane))
        controller.toggleCommandTimeline(nil)
        controller.window?.layoutIfNeeded()
        let sidebar = controller.timelineSidebar!
        let first = try #require(sidebar.rows.firstIndex { $0.entry?.command == "echo first" })
        sidebar.table.selectRowIndexes([first], byExtendingSelection: false)
        #expect(sidebar.go(to: sidebar.rows[first].entry!))
        sidebar.focusTerminal()

        // Typed in the terminal: Return is still the key event AppKit is handling when the new command
        // reloads the list.
        sidebar.handlingKeyPress = { true }
        pane.terminal.send(txt: "seq 1 70")
        #expect(await waitUntil { pane.terminal.visibleRowsText(0..<40).joined().contains("seq 1 70") })
        pane.terminal.send(txt: "\r")
        #expect(await waitUntil { sidebar.rows.last?.entry?.command == "seq 1 70" && pane.isAtCommandLine })
        try await Task.sleep(for: .milliseconds(100))

        let grid = try #require(TerminalGrid(terminal: pane.terminal))
        #expect(grid.rows.contains { $0.text.trimmingCharacters(in: .whitespaces) == "70" })
        #expect(sidebar.selectedEntry?.command == "echo first")
    }

    /// Showing and hiding: the button and ⇧⌘L always toggle, and hiding gives the terminal back the keyboard,
    /// wherever it was in the sidebar.
    @Test func showingAndHidingTheSidebar() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let controller = TerminalWindowController(directory: env.directory.path, environment: env.environment)
        controller.window?.setContentSize(NSSize(width: 1000, height: 500))
        controller.window?.layoutIfNeeded()
        defer {
            controller.model.tabs.flatMap(\.panes).forEach { $0.shutDown() }
            controller.window?.close()
        }
        let pane = try #require(controller.model.selected?.focused)
        let window = try #require(controller.window)
        let sidebar = controller.timelineSidebar!
        func shown() -> Bool {
            window.layoutIfNeeded()
            return controller.model.timelineVisible && !sidebar.isHidden && sidebar.frame.width > 0
        }

        controller.toggleCommandTimeline(nil)
        #expect(shown())
        #expect(window.firstResponder === sidebar.table)
        controller.toggleCommandTimeline(nil)
        #expect(!shown())
        #expect(window.firstResponder === pane.terminal)

        // Open while typing in the terminal: the button closes it rather than moving the keyboard.
        controller.toggleCommandTimeline(nil)
        window.makeFirstResponder(pane.terminal)
        controller.toggleCommandTimeline(nil)
        #expect(!shown())
        #expect(window.firstResponder === pane.terminal)

        controller.toggleCommandTimeline(nil)
        window.makeFirstResponder(sidebar.searchField)
        controller.toggleCommandTimeline(nil)
        #expect(!shown())
        #expect(window.firstResponder === pane.terminal)
    }

    /// In a narrow window, the sidebar opens narrower so the terminal keeps some room.
    @Test func leavesTheTerminalRoomInANarrowWindow() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let controller = TerminalWindowController(directory: env.directory.path, environment: env.environment)
        controller.window?.setContentSize(NSSize(width: 780, height: 500))
        controller.window?.layoutIfNeeded()
        defer {
            controller.model.tabs.flatMap(\.panes).forEach { $0.shutDown() }
            controller.window?.close()
        }
        controller.setFileTreeVisible(true)
        controller.toggleCommandTimeline(nil)
        controller.window?.layoutIfNeeded()
        #expect(controller.timelineSidebar.frame.width == 780 - FileTreeSidebar.defaultWidth - 320)
        #expect(controller.paneContainer.frame.width == 320)

        // The width the user chose comes back when there's room again.
        controller.toggleCommandTimeline(nil)
        controller.window?.setContentSize(NSSize(width: 1200, height: 500))
        controller.toggleCommandTimeline(nil)
        controller.window?.layoutIfNeeded()
        #expect(controller.timelineSidebar.frame.width == CommandTimelineSidebar.defaultWidth)
    }

    /// Once the buffer is cleared the command can't be scrolled to, but its output was kept.
    @Test func keepsOutputAfterTheBufferIsCleared() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let (pane, window) = try zshPane(env)
        defer { pane.shutDown(); window.close() }
        #expect(await waitUntil { pane.isAtCommandLine })
        #expect(await run("printf 'kept\\nfor later\\n'", in: pane))
        let entry = try #require(pane.timeline.entries.first)
        #expect(pane.rows(of: entry) != nil)

        pane.clearBuffer()
        #expect(await waitUntil { pane.isAtCommandLine })
        #expect(await run("echo after", in: pane))
        let cleared = try #require(pane.timeline.entries.first)
        #expect(pane.rows(of: cleared) == nil)
        #expect(pane.reveal(cleared) == nil)
        #expect(pane.output(of: cleared) == "kept\nfor later")
        #expect(pane.rows(of: pane.timeline.entries[1]) != nil)
    }

    /// `clear` resets the scrollback from the shell, without Codec knowing: the content check catches it.
    @Test func noticesWhenTheShellClearedTheScrollback() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let (pane, window) = try zshPane(env)
        defer { pane.shutDown(); window.close() }
        #expect(await waitUntil { pane.isAtCommandLine })
        #expect(await run("echo one", in: pane))
        #expect(await run("printf '\\e[H\\e[2J\\e[3J'", in: pane))
        let first = try #require(pane.timeline.entries.first)
        #expect(pane.rows(of: first) == nil)
        #expect(pane.output(of: first) == "one")
    }

    @Test func showsTheFocusedPanesCommandsInTheSidebar() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        try useCleanZsh(env)
        let controller = TerminalWindowController(directory: env.directory.path, environment: env.environment)
        unsetenv("ZDOTDIR")
        controller.window?.setContentSize(NSSize(width: 1100, height: 600))
        controller.window?.layoutIfNeeded()
        defer {
            controller.model.tabs.flatMap(\.panes).forEach { $0.shutDown() }
            controller.window?.close()
        }
        let pane = try #require(controller.model.selected?.focused)
        #expect(!controller.model.timelineVisible)
        #expect(controller.timelineSidebar.frame.width == 0)

        #expect(await waitUntil { pane.isAtCommandLine })
        #expect(await run("echo hello", in: pane))
        #expect(await run("ls /nonexistent-codec-path", in: pane))

        controller.toggleCommandTimeline(nil)
        controller.window?.layoutIfNeeded()
        let sidebar = controller.timelineSidebar!
        #expect(controller.model.timelineVisible)
        #expect(sidebar.frame.width == CommandTimelineSidebar.defaultWidth)
        #expect(sidebar.pane === pane)
        #expect(sidebar.rows.compactMap(\.entry).map(\.command) == ["echo hello", "ls /nonexistent-codec-path"])
        if case .directory = sidebar.rows.first {} else { Issue.record("The list starts with the directory") }
        #expect(sidebar.selectedEntry?.command == "ls /nonexistent-codec-path")
        #expect(controller.window?.firstResponder === sidebar.table)

        // New commands show up as they run.
        #expect(await run("echo again", in: pane))
        #expect(await waitUntil { sidebar.rows.last?.entry?.command == "echo again" })

        // Filtering looks in the output too.
        sidebar.searchField.stringValue = "hello"
        sidebar.reload()
        #expect(sidebar.rows.compactMap(\.entry).map(\.command) == ["echo hello"])
        sidebar.searchField.stringValue = ""
        sidebar.reload()

        let entry = try #require(sidebar.rows.compactMap(\.entry).first)
        #expect(sidebar.contextMenuItems(for: entry, row: 1).map { $0.isSeparatorItem ? "-" : $0.title } == [
            "Go to Command", "Show Output", "-", "Save to Intel…", "-", "Copy Command", "Copy Output", "Select Output", "-",
            "Insert Command", "Run Again", "-", "Copy Folder Path",
        ])
        sidebar.showOutput(of: entry, row: 1)
        #expect(sidebar.outputViewer?.output == "hello")
        _ = sidebar.outputViewer?.view
        #expect(sidebar.outputViewer?.textView.string == "hello")

        // A second pane: the sidebar follows the focus.
        controller.splitRight(nil)
        let second = try #require(controller.model.selected?.focused)
        #expect(second !== pane)
        #expect(sidebar.pane === second)
        #expect(await waitUntil { second.isAtCommandLine })
        #expect(sidebar.rows.isEmpty)

        controller.toggleCommandTimeline(nil)
        controller.window?.layoutIfNeeded()
        #expect(!controller.model.timelineVisible)
        #expect(controller.timelineSidebar.frame.width == 0)
        #expect(controller.paletteCommands().contains { $0.id == "commands" && $0.title == "Show Commands Sidebar" })
    }

    /// ⇧⌘F: every pane's commands, in every tab, under the pane they ran in, filtered as Find matches;
    /// going to one selects its tab and pane and opens Find there.
    @Test func searchesEveryPanesOutput() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        try useCleanZsh(env)
        defer { unsetenv("ZDOTDIR") }
        let controller = TerminalWindowController(directory: env.directory.path, environment: env.environment)
        controller.window?.setContentSize(NSSize(width: 1100, height: 600))
        controller.window?.layoutIfNeeded()
        var others: [TerminalWindowController] = []
        defer {
            for window in [controller] + others {
                window.model.tabs.flatMap(\.panes).forEach { $0.shutDown() }
                window.window?.close()
            }
        }
        // The commands don't hold what's searched for; their output does.
        let left = try #require(controller.model.selected?.focused)
        #expect(await waitUntil { left.isAtCommandLine })
        #expect(await run("echo 'Error: connect ECONN''REFUSED 127.0.0.1:5432'", in: left))
        controller.splitRight(nil)
        let right = try #require(controller.model.selected?.focused)
        #expect(await waitUntil { right.isAtCommandLine })
        #expect(await run("echo all good", in: right))
        let firstTab = try #require(controller.model.selected)
        controller.newTab(nil)
        let other = try #require(controller.model.selected?.focused)
        #expect(await waitUntil { other.isAtCommandLine })
        #expect(await run("echo 'bind: econn''refused too'", in: other))
        let secondTab = try #require(controller.model.selected)

        controller.findInAllPanes(nil)
        let sidebar = controller.timelineSidebar!
        #expect(controller.model.timelineVisible)
        #expect(sidebar.scope == .all)
        #expect(sidebar.scopeControl.selectedSegment == 1)
        #expect((controller.window?.firstResponder as? NSText)?.delegate === sidebar.searchField)

        sidebar.searchField.stringValue = "ECONNREFUSED"
        sidebar.reload()
        let directory = left.session.directory
        #expect(sidebar.rows == [
            .pane("\(firstTab.title) › left", directory: directory),
            .entry(left.timeline.entries[0]),
            .pane(secondTab.title, directory: directory),
            .entry(other.timeline.entries[0]),
        ])
        let cell = try #require(sidebar.table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? TimelineCell)
        #expect(cell.shown.detail == "Error: connect ECONNREFUSED 127.0.0.1:5432")

        // Find's options apply.
        sidebar.toggles.options = FindOptions(caseSensitive: true)
        sidebar.reload()
        #expect(sidebar.rows.compactMap(\.entry).map(\.command) == [left.timeline.entries[0].command])
        sidebar.toggles.options = FindOptions(regex: true)
        sidebar.searchField.stringValue = "good|too$"
        sidebar.reload()
        #expect(sidebar.rows.compactMap(\.entry).map(\.command) == ["echo all good", "echo 'bind: econn''refused too'"])
        #expect(sidebar.rows.first == .pane("\(firstTab.title) › right", directory: directory))
        sidebar.searchField.stringValue = "("
        sidebar.reload()
        #expect(sidebar.rows.isEmpty)
        sidebar.toggles.options = FindOptions()
        sidebar.searchField.stringValue = "econnrefused"
        sidebar.reload()

        // Going to a command in the other tab selects it, and opens Find there on the line that matched.
        let hit = try #require(sidebar.row(of: left.timeline.entries[0], in: left))
        sidebar.table.selectRowIndexes([hit], byExtendingSelection: false)
        sidebar.goToSelected(focusTerminal: true)
        #expect(controller.model.selected === firstTab)
        #expect(firstTab.focused === left)
        let finder = left.view.finder
        #expect(finder.isOpen)
        #expect(finder.bar.query == "econnrefused")
        let current = try #require(finder.current)
        let block = try #require(left.timeline.entries[0].block)
        #expect(finder.matches[current].row == block.output)
        #expect(sidebar.scope == .all)
        #expect(sidebar.rows.compactMap(\.entry).count == 2)
        #expect(sidebar.pane === left)

        // Back to this pane's commands.
        sidebar.setScope(.pane)
        #expect(sidebar.rows.compactMap(\.entry).map(\.command) == [left.timeline.entries[0].command])

        // With several windows, each pane says which window it's in.
        let second = TerminalWindowController(directory: env.directory.path, environment: env.environment)
        others.append(second)
        env.coordinator.terminalWindows = [controller, second]
        let titles = controller.panePlaces().map(\.title)
        #expect(titles.count == 4)
        #expect(titles.prefix(3).allSatisfy { $0.hasPrefix("Window 1 › ") })
        #expect(titles.last?.hasPrefix("Window 2 › ") == true)
    }

    /// Regression: after a resize, zsh printed a prompt of several lines again below the old one's
    /// upper lines, leaving them twice on screen.
    @Test func aResizeRedrawsATallPromptInPlace() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        var prompt = PromptConfiguration.default
        prompt.style = .codec
        env.preferences.prompt = prompt
        let config = env.directory.appendingPathComponent("zdotdir")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "".write(to: config.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        setenv("ZDOTDIR", config.path, 1)
        defer { unsetenv("ZDOTDIR") }
        let controller = TerminalWindowController(directory: env.directory.path, environment: env.environment)
        defer { controller.window?.close() }
        controller.window?.setContentSize(NSSize(width: 900, height: 500))
        controller.window?.layoutIfNeeded()
        let pane = try #require(controller.model.selected?.focused)
        #expect(await waitUntil { pane.isAtCommandLine })
        #expect(await run("echo resized-later", in: pane))
        try await Task.sleep(for: .milliseconds(300))

        func screen() -> [String] {
            pane.terminal.terminalContentSnapshot(region: .history(maximumScrollbackRows: 100))?.rows
                .map { $0.text.trimmingCharacters(in: .whitespaces) } ?? []
        }
        func promptsAfterOutput() -> (contexts: Int, symbols: Int) {
            let rows = screen()
            guard let output = rows.lastIndex(of: "resized-later") else { return (0, 0) }
            let after = rows[(output + 1)...]
            return (after.filter { $0.hasPrefix(env.directory.lastPathComponent) || $0.contains("codec-ui-tests") }.count,
                    after.filter { $0.hasPrefix("❯") }.count)
        }
        let before = promptsAfterOutput()
        #expect(before.symbols == 1)

        // Shorter, as when splitting down; then narrower and wider in quick succession, as when dragging.
        controller.splitDown(nil)
        controller.window?.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(800))
        #expect(promptsAfterOutput() == before)
        for width in [700.0, 560, 820] {
            controller.window?.setContentSize(NSSize(width: width, height: 500))
            controller.window?.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .milliseconds(1000))
        let after = promptsAfterOutput()
        #expect(after.symbols == 1)
        // The command and its output are untouched.
        #expect(screen().contains("❯ echo resized-later") && screen().contains("resized-later"))
        #expect(pane.isAtCommandLine)
    }
}
