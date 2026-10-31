import Testing
import AppKit
import CodecCore
@testable import CodecUI

@Suite("History store", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct HistoryStoreTests {
    private func entry(_ command: String, _ seconds: Double = 0, exit: Int32 = 0) -> HistoryEntry {
        HistoryEntry(command: command, date: Date(timeIntervalSince1970: 1_700_000_000 + seconds), directory: "/repo",
                     exitCode: exit, duration: 0.5)
    }

    @Test func keepsWhatItRecordsAcrossLaunches() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let log = env.directory.appendingPathComponent("log/history.jsonl")
        let store = HistoryStore(logURL: log)
        store.record(entry("make", 0))
        store.record(entry("make test", 1, exit: 1))
        store.record(entry(" secret", 2))
        store.record(entry("ls", 3))
        store.forget("ls")
        #expect(store.history.entries.map(\.command) == ["make", "make test"])

        let reopened = HistoryStore(logURL: log)
        reopened.load()
        await reopened.loaded()
        #expect(reopened.history.entries.map(\.command) == ["make", "make test"])
        #expect(reopened.history.entries.last?.exitCode == 1)

        reopened.clear()
        let cleared = HistoryStore(logURL: log)
        cleared.load()
        await cleared.loaded()
        #expect(cleared.history.entries.isEmpty)
    }

    @Test func includesTheShellsHistoryFile() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let shellFile = env.directory.appendingPathComponent(".zsh_history")
        try ": 1700000000:0;git pull\n: 1700000100:0;make\n".write(to: shellFile, atomically: true, encoding: .utf8)
        let store = HistoryStore(logURL: nil)
        store.record(entry("make", 200, exit: 2))
        store.useShellFile(shellFile)
        await store.loaded()
        let items = store.history.items(matching: "")
        #expect(items.map(\.command) == ["make", "git pull"])
        #expect(items.first?.count == 2)
        #expect(items.first?.failed == true)

        // Forgetting hides the shell's copies too.
        store.forget("git pull")
        #expect(store.history.items(matching: "").map(\.command) == ["make"])
        // Changes to the file are picked up.
        try ": 1700000000:0;git pull\n: 1700000100:0;make\n: 1700000300:0;npm test\n".write(to: shellFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: shellFile.path)
        store.load()
        await store.loaded()
        #expect(store.history.items(matching: "npm").map(\.command) == ["npm test"])
    }
}

@Suite("History in zsh panes", .serialized, .timeLimit(.minutes(1)),
       .enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")))
@MainActor
struct HistoryPaneTests {
    private func zshPane(_ env: TestEnvironment, host: FakeHost) throws -> Pane {
        let config = env.directory.appendingPathComponent("zdotdir")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "PS1='%# '\nHISTFILE=\(config.path)/.zsh_history\n".write(to: config.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        setenv("ZDOTDIR", config.path, 1)
        defer { unsetenv("ZDOTDIR") }
        return env.makePane(host: host)
    }

    @Test func recordsCommandsWithWhereAndHowTheyRan() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let pane = try zshPane(env, host: FakeHost())
        defer { pane.shutDown() }
        #expect(await waitUntil { pane.isAtCommandLine })
        pane.terminal.send(txt: "false\r")
        #expect(await waitUntil { env.environment.history.history.entries.contains { $0.command == "false" } })
        let entry = try #require(env.environment.history.history.entries.last { $0.command == "false" })
        #expect(entry.exitCode == 1)
        // Where the shell was: its real path (/private/var…).
        #expect(entry.directory == pane.session.directory)
        #expect(entry.directory?.hasSuffix(env.directory.lastPathComponent) == true)
        #expect(entry.source == .codec)

        // Every line of a multi-line command.
        pane.terminal.send(txt: "echo one \\\r")
        pane.terminal.send(txt: "two\r")
        #expect(await waitUntil { env.environment.history.history.entries.contains { $0.command == "echo one \\\ntwo" } })
    }

    @Test func respectsTheSetting() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        env.preferences.recordHistory = false
        let pane = try zshPane(env, host: FakeHost())
        defer { pane.shutDown() }
        #expect(await waitUntil { pane.isAtCommandLine })
        pane.terminal.send(txt: "true\r")
        #expect(await waitUntil { pane.session.lastCommand != nil })
        #expect(!env.environment.history.history.entries.contains { $0.command == "true" })
    }

    @Test func upArrowAsksForTheMenuAndAPickReplacesTheLine() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let host = FakeHost()
        let pane = try zshPane(env, host: host)
        defer { pane.shutDown() }
        #expect(await waitUntil { pane.isAtCommandLine })
        pane.terminal.send(txt: "git st")
        pane.terminal.send(txt: "\u{1b}[A")
        #expect(await waitUntil { host.historyRequests.contains { $0.0 == .menu && $0.1 == "git st" } })

        #expect(pane.replaceCommandLine(with: "echo picked", run: true))
        #expect(await waitUntil { pane.session.lastCommand?.command == "echo picked" })
    }
}

@Suite("History in a window", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct HistoryWindowTests {
    @Test func showsTheMenuAndThePanel() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        env.environment.history.record(HistoryEntry(command: "make test", date: Date(), directory: env.directory.path, exitCode: 0))
        let controller = TerminalWindowController(directory: env.directory.path, environment: env.environment)
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 600))
        window.orderBack(nil)
        defer { window.close() }
        let pane = try #require(controller.model.selected?.focused)

        controller.showHistory(for: pane, request: .menu, typed: "make")
        #expect(await waitUntil { controller.isShowingHistoryMenu })

        controller.showHistory(for: pane, request: .search, typed: "")
        #expect(controller.isShowingHistoryPanel)
        // The menu gives way, once its closing animation ends.
        #expect(await waitUntil { !controller.isShowingHistoryMenu })
        #expect(controller.model.paletteOpen)
        controller.showCommandHistory(nil)
        #expect(!controller.isShowingHistoryPanel)
        #expect(controller.paletteCommands().contains { $0.id == "command-history" })
    }
}

@Suite("History and palette keyboard", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct OverlayKeyboardTests {
    private func key(_ code: UInt16, _ characters: String, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private func inOverlay(_ controller: TerminalWindowController) -> Bool {
        (controller.window?.firstResponder as? NSView)?.isDescendant(of: controller.palette) ?? false
    }

    private func makeWindow(_ env: TestEnvironment) throws -> (TerminalWindowController, NSWindow, Pane) {
        let controller = TerminalWindowController(directory: env.directory.path, environment: env.environment)
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 600))
        window.orderBack(nil)
        return (controller, window, try #require(controller.model.selected?.focused))
    }

    /// Regression: ⌃R opened the search but the keyboard stayed in the terminal, so Esc and typing
    /// went to the shell.
    @Test func theSearchTakesTheKeyboardAndEscapeClosesIt() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let (controller, window, pane) = try makeWindow(env)
        defer { window.close() }
        controller.showHistory(for: pane, request: .search, typed: "")
        #expect(await waitUntil(timeout: .seconds(3)) { inOverlay(controller) })

        // Something takes the keyboard back; the next key brings it to the search field.
        window.makeFirstResponder(pane.terminal)
        #expect(!controller.handleOverlayKey(key(0, "a", in: window)))
        #expect(inOverlay(controller))

        #expect(controller.handleOverlayKey(key(53, "\u{1b}", in: window)))
        #expect(!controller.isShowingHistoryPanel)
        #expect(!controller.model.paletteOpen)
        #expect(window.firstResponder === pane.terminal)
        // Closed, keys go back to the terminal untouched.
        #expect(!controller.handleOverlayKey(key(53, "\u{1b}", in: window)))
    }

    @Test func thePaletteToo() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let (controller, window, _) = try makeWindow(env)
        defer { window.close() }
        controller.showCommandPalette(nil)
        #expect(await waitUntil(timeout: .seconds(3)) { inOverlay(controller) })
        #expect(controller.handleOverlayKey(key(53, "\u{1b}", in: window)))
        #expect(!controller.model.paletteOpen)
    }

    @Test func escapeClosesTheHistoryMenu() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let (controller, window, pane) = try makeWindow(env)
        defer { window.close() }
        controller.showHistory(for: pane, request: .menu, typed: "")
        #expect(await waitUntil { controller.isShowingHistoryMenu })
        #expect(controller.handleOverlayKey(key(53, "\u{1b}", in: window)))
        #expect(await waitUntil { !controller.isShowingHistoryMenu })
    }
}
