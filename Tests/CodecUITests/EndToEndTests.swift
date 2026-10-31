import Testing
import Foundation
import AppKit
import CodecCore
@testable import CodecUI

/// A real zsh, with Codec's integration, running in a real pane: what the user gets.
@Suite("End to end with zsh", .serialized, .timeLimit(.minutes(1)),
       .enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")))
@MainActor
struct EndToEndTests {
    /// Isolates zsh from the user's own configuration by pointing ZDOTDIR at an empty folder.
    private func makeZshPane(_ env: TestEnvironment, host: FakeHost) throws -> Pane {
        let config = env.directory.appendingPathComponent("zdotdir")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "PS1='%# '\n".write(to: config.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        setenv("ZDOTDIR", config.path, 1)
        defer { unsetenv("ZDOTDIR") }
        return env.makePane(host: host)
    }

    @Test func tracksCommandsDirectoryAndBranch() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let repo = env.directory.appendingPathComponent("repo/.git")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "ref: refs/heads/trunk\n".write(to: repo.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

        let host = FakeHost()
        let pane = try makeZshPane(env, host: host)
        defer { pane.shutDown() }
        #expect(await waitUntil { pane.session.integrated || pane.terminal.process.running })

        pane.terminal.send(txt: "cd repo && false\r")
        #expect(await waitUntil { pane.session.lastCommand != nil })
        #expect(pane.session.integrated)
        #expect(pane.session.lastCommand?.command == "cd repo && false")
        #expect(pane.session.lastCommand?.exitCode == 1)
        #expect(await waitUntil { pane.session.directory.hasSuffix("/repo") })
        #expect(pane.session.gitBranch == "trunk")

        pane.terminal.send(txt: "sleep 0.3\r")
        #expect(await waitUntil { pane.session.running?.command == "sleep 0.3" || pane.session.lastCommand?.command == "sleep 0.3" })
        #expect(await waitUntil { pane.session.lastCommand?.command == "sleep 0.3" })
        #expect(pane.session.lastCommand?.exitCode == 0)
        #expect((pane.session.lastCommand?.duration ?? 0) >= 0.3)
        #expect(pane.session.running == nil)
    }

    /// The command line can be edited at the first prompt, before any command ran, and never while one runs.
    @Test func knowsWhenTheCommandLineIsEditable() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let pane = try makeZshPane(env, host: FakeHost())
        defer { pane.shutDown() }
        #expect(await waitUntil { pane.isAtCommandLine })
        pane.terminal.send(txt: "sleep 1\r")
        #expect(await waitUntil { pane.session.running != nil })
        #expect(!pane.isAtCommandLine)
        #expect(await waitUntil { pane.isAtCommandLine })
    }

    /// A triple-click on the command line selects it, so typing replaces it; one on earlier output doesn't.
    @Test func tripleClickSelectsTheCommandLine() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let pane = try makeZshPane(env, host: FakeHost())
        defer { pane.shutDown() }
        let window = makeTestWindow()
        defer { window.close() }
        window.contentView = pane.view
        pane.view.layoutSubtreeIfNeeded()
        #expect(await waitUntil { pane.isAtCommandLine })

        pane.terminal.send(txt: "echo old")
        #expect(await waitUntil { pane.terminal.visibleRowsText(0..<5).joined().contains("echo old") })
        let grid = try #require(TerminalGrid(terminal: pane.terminal))
        func press(at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 3, pressure: 1)!
        }
        let onCommandLine = NSPoint(x: grid.caret.minX - 3 * grid.caret.width, y: grid.caret.midY)
        let aboveIt = NSPoint(x: onCommandLine.x, y: grid.caret.midY + 3 * grid.caret.height)
        #expect(!pane.beginCommandLineGesture(press(at: aboveIt)))
        #expect(pane.beginCommandLineGesture(press(at: onCommandLine)))
        pane.terminal.send(txt: "echo new\r")
        #expect(await waitUntil { pane.session.lastCommand != nil })
        #expect(pane.session.lastCommand?.command == "echo new")
    }

    @Test func editingShortcutsDriveTheShell() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let pane = try makeZshPane(env, host: FakeHost())
        defer { pane.shutDown() }
        #expect(await waitUntil { pane.isAtCommandLine })
        pane.terminal.send(txt: "cho hi")
        pane.editCommandLine(.moveToStart)
        pane.terminal.send(txt: "e")
        pane.editCommandLine(.moveToEnd)
        pane.terminal.send(txt: " there\r")
        #expect(await waitUntil { pane.session.lastCommand != nil })
        #expect(pane.session.lastCommand?.command == "echo hi there")
    }

    @Test func exitClosesThePane() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let host = FakeHost()
        let pane = try makeZshPane(env, host: host)
        defer { pane.shutDown() }
        #expect(await waitUntil { pane.terminal.process.running })
        pane.terminal.send(txt: "exit\r")
        #expect(await waitUntil { host.finished == 1 })
    }
}
