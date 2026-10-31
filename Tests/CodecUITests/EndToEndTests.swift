import Testing
import Foundation
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
