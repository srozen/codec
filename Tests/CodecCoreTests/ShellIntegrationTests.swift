import Testing
import Foundation
import Synchronization
import SwiftTerm
@testable import CodecCore

@Suite("ShellIntegration")
struct ShellIntegrationTests {
    @Test func supportsOnlyZsh() {
        #expect(ShellIntegration.supports(shell: "/bin/zsh"))
        #expect(ShellIntegration.supports(shell: "zsh"))
        #expect(!ShellIntegration.supports(shell: "/bin/bash"))
        #expect(!ShellIntegration.supports(shell: "/opt/homebrew/bin/fish"))
    }

    @Test func pointsZshAtTheIntegrationDirectory() {
        let integration = ShellIntegration(directory: URL(fileURLWithPath: "/tmp/codec-si"))
        let env = integration.environment(["PATH": "/bin"], forShell: "/bin/zsh")
        #expect(env["ZDOTDIR"] == "/tmp/codec-si/zsh")
        #expect(env["CODEC_SHELL_INTEGRATION"] == "/tmp/codec-si/zsh/codec-integration.zsh")
        #expect(env["CODEC_ORIG_ZDOTDIR"] == nil)
        #expect(env["PATH"] == "/bin")
    }

    @Test func remembersTheUsersZdotdir() {
        let integration = ShellIntegration(directory: URL(fileURLWithPath: "/tmp/codec-si"))
        let env = integration.environment(["ZDOTDIR": "/Users/me/.config/zsh"], forShell: "zsh")
        #expect(env["CODEC_ORIG_ZDOTDIR"] == "/Users/me/.config/zsh")
        #expect(env["ZDOTDIR"] == "/tmp/codec-si/zsh")
    }

    @Test func leavesOtherShellsAlone() {
        let integration = ShellIntegration(directory: URL(fileURLWithPath: "/tmp/codec-si"))
        let original = ["ZDOTDIR": "/x", "HOME": "/Users/me"]
        #expect(integration.environment(original, forShell: "/bin/bash") == original)
    }

    @Test func installsTheScripts() throws {
        let temp = try TemporaryDirectory()
        let integration = ShellIntegration(directory: temp.url.appendingPathComponent("si"))
        try integration.install()
        try integration.install() // Reinstalling replaces the files.
        let zshenv = try String(contentsOf: integration.zshDirectory.appendingPathComponent(".zshenv"), encoding: .utf8)
        let hooks = try String(contentsOf: integration.zshScript, encoding: .utf8)
        #expect(zshenv.contains("CODEC_ORIG_ZDOTDIR"))
        #expect(hooks.contains("133;A"))
        #expect(hooks.contains("6973;done"))
        #expect(hooks.contains("precmd_functions"))
    }
}

/// OSC events collected from SwiftTerm's delivery queue.
private final class EventLog: Sendable {
    let events = Mutex<[TerminalOscEvent]>([])
}

/// Runs a real interactive zsh with the integration loaded, in a headless terminal.
private final class ZshHarness: @unchecked Sendable {
    let temp: TemporaryDirectory
    let home: URL
    private let log = EventLog()
    private let terminal: HeadlessTerminal
    private var observation: TerminalOscObservation?

    init(zdotdir: String? = nil, homeFiles: [String: String] = [:]) throws {
        temp = try TemporaryDirectory()
        home = try temp.directory("home")
        for (path, contents) in homeFiles {
            try temp.file("home/\(path)", contents)
        }
        let integration = ShellIntegration(directory: temp.url.appendingPathComponent("integration"))
        try integration.install()

        var base = [
            "HOME": home.path, "TERM": "xterm-256color", "LANG": "en_US.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "USER": NSUserName(),
        ]
        if let zdotdir { base["ZDOTDIR"] = zdotdir }
        let environment = integration.environment(base, forShell: "/bin/zsh")

        terminal = HeadlessTerminal(queue: DispatchQueue(label: "codec.tests.zsh")) { _ in }
        observation = terminal.terminal.observeOscEvents { [log] event in
            log.events.withLock { $0.append(event) }
        }
        terminal.process.startProcess(executable: "/bin/zsh", args: ["-i"],
                                      environment: environment.map { "\($0.key)=\($0.value)" },
                                      execName: "-zsh", currentDirectory: home.path)
    }

    deinit {
        observation?.cancel()
        terminal.process.terminate()
    }

    func send(_ text: String) {
        terminal.process.send(data: Array(text.utf8)[...])
    }

    /// OSC payloads with this code, in arrival order.
    func payloads(_ code: Int) -> [String] {
        log.events.withLock { $0.filter { $0.code == code }.map { String(decoding: $0.payload, as: UTF8.self) } }
    }

    /// Polls until `condition` holds or the timeout passes.
    func wait(timeout: Duration = .seconds(15), until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}

@Suite("Shell integration in zsh", .enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")),
       .timeLimit(.minutes(1)))
struct ZshIntegrationTests {
    @Test func marksPromptsAndReportsTheWorkingDirectory() async throws {
        let zsh = try ZshHarness()
        #expect(await zsh.wait { zsh.payloads(133).contains("A") })
        let directories = zsh.payloads(7)
        #expect(directories.contains { $0.hasPrefix("file://") && $0.hasSuffix(zsh.home.path) })
    }

    @Test func reportsCommandsWithTheirStatusAndDuration() async throws {
        let zsh = try ZshHarness()
        #expect(await zsh.wait { zsh.payloads(133).contains("A") })
        zsh.send("sleep 0.2; false\r")
        #expect(await zsh.wait { zsh.payloads(6973).contains { $0.hasPrefix("done;") } })

        let events = zsh.payloads(6973).compactMap(IntegrationEvent.init(payload:))
        #expect(events.first == .commandStarted("sleep 0.2; false"))
        guard case .commandFinished(let code, let duration) = events.last else {
            Issue.record("No finish event in \(events)")
            return
        }
        #expect(code == 1)
        #expect(duration >= 0.2 && duration < 10)
        #expect(zsh.payloads(133).contains("C"))
        #expect(zsh.payloads(133).contains("D;1"))
    }

    @Test func reportsSuccessAndDirectoryChanges() async throws {
        let zsh = try ZshHarness()
        #expect(await zsh.wait { zsh.payloads(133).contains("A") })
        zsh.send("mkdir -p 'with space' && cd 'with space'\r")
        #expect(await zsh.wait { zsh.payloads(6973).contains { $0.hasPrefix("done;") } })
        #expect(zsh.payloads(6973).last == zsh.payloads(6973).last.flatMap { $0.hasPrefix("done;0;") ? $0 : nil })
        #expect(await zsh.wait { zsh.payloads(7).contains { $0.hasSuffix("/home/with%20space") } })
    }

    @Test func stillLoadsTheUsersStartupFiles() async throws {
        let zsh = try ZshHarness(homeFiles: [
            ".zshenv": "export CODEC_TEST_ENV=1\n",
            ".zshrc": "print -rn -- $'\\e]9999;zshrc-env='\"$CODEC_TEST_ENV\"$'\\a'\n",
        ])
        #expect(await zsh.wait { zsh.payloads(9999).contains("zshrc-env=1") })
        #expect(await zsh.wait { zsh.payloads(133).contains("A") })
    }

    @Test func honorsACustomZdotdir() async throws {
        let config = try TemporaryDirectory()
        try config.file(".zshrc", "print -rn -- $'\\e]9999;custom-zdotdir\\a'\n")
        let zsh = try ZshHarness(zdotdir: config.url.path)
        #expect(await zsh.wait { zsh.payloads(9999).contains("custom-zdotdir") })
        zsh.send("print -rn -- $'\\e]9999;'\"$ZDOTDIR\"$'\\a'\r")
        #expect(await zsh.wait { zsh.payloads(9999).contains(config.url.path) })
    }
}
