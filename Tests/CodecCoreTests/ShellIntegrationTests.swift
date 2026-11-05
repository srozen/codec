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

private extension PromptConfiguration {
    /// The user's own prompt, from their zsh configuration.
    static var shellPrompt: PromptConfiguration {
        var prompt = PromptConfiguration.default
        prompt.style = .shell
        return prompt
    }
}

/// Runs a real interactive zsh with the integration loaded, in a headless terminal.
private final class ZshHarness: @unchecked Sendable {
    let temp: TemporaryDirectory
    let home: URL
    private let log = EventLog()
    private let terminal: HeadlessTerminal
    private var observation: TerminalOscObservation?

    let integration: ShellIntegration

    init(zdotdir: String? = nil, homeFiles: [String: String] = [:], prompt: PromptConfiguration? = nil,
         directory: String? = nil, environment extra: [String: String] = [:]) throws {
        temp = try TemporaryDirectory()
        home = try temp.directory("home")
        for (path, contents) in homeFiles {
            try temp.file("home/\(path)", contents)
        }
        integration = ShellIntegration(directory: temp.url.appendingPathComponent("integration"))
        try integration.install()
        // Without one given, the prompt from the .zshrc, as the tests set it.
        try integration.writePrompt(prompt ?? .shellPrompt)

        var base = [
            "HOME": realPath(home), "TERM": "xterm-256color", "LANG": "en_US.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "USER": NSUserName(),
        ]
        if let zdotdir { base["ZDOTDIR"] = zdotdir }
        base.merge(extra) { _, new in new }
        let environment = integration.environment(base, forShell: "/bin/zsh")

        terminal = HeadlessTerminal(queue: DispatchQueue(label: "codec.tests.zsh")) { _ in }
        observation = terminal.terminal.observeOscEvents { [log] event in
            log.events.withLock { $0.append(event) }
        }
        terminal.process.startProcess(executable: "/bin/zsh", args: ["-i"],
                                      environment: environment.map { "\($0.key)=\($0.value)" },
                                      execName: "-zsh", currentDirectory: directory ?? home.path)
    }

    deinit {
        observation?.cancel()
        terminal.process.terminate()
    }

    func send(_ text: String) {
        terminal.process.send(data: Array(text.utf8)[...])
    }

    func sendBytes(_ bytes: [UInt8]) {
        terminal.process.send(data: bytes[...])
    }

    /// Asks the shell to report its current PROMPT (minus control characters) as OSC 9999.
    func reportPrompt() {
        send(#"print -rn -- $'\e]9999;prompt='"${${PROMPT//$'\e'/}//$'\a'/}"$'\a'"# + "\r")
    }

    /// Asks the shell for its prompt as zsh draws it (prompt escapes expanded), base64-encoded.
    func reportExpandedPrompt() {
        send(#"print -rn -- $'\e]9999;expanded='"$(print -rn -- "${(%)PROMPT}" | /usr/bin/base64)"$'\a'"# + "\r")
    }

    /// Expanded prompts reported so far, with color and other escape sequences removed.
    var expandedPrompts: [String] {
        rawExpandedPrompts.map { raw in
            raw.replacingOccurrences(of: "\u{1b}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\u{1b}\\][^\u{07}]*\u{07}", with: "", options: .regularExpression)
        }
    }

    /// Expanded prompts with their escape sequences.
    var rawExpandedPrompts: [String] {
        payloads(9999).filter { $0.hasPrefix("expanded=") }.compactMap { payload in
            Data(base64Encoded: String(payload.dropFirst("expanded=".count))).map { String(decoding: $0, as: UTF8.self) }
        }
    }

    /// Where the terminal's cursor is.
    var cursor: (x: Int, y: Int) {
        terminal.terminal.terminalLock.withLock { terminal.terminal.getCursorLocation() }
    }

    var reportedPrompts: [String] {
        payloads(9999).filter { $0.hasPrefix("prompt=") }.map { String($0.dropFirst("prompt=".count)) }
    }

    /// The screen's lines, as text.
    var screen: [String] {
        terminal.terminal.terminalLock.withLock {
            (0..<terminal.terminal.rows).compactMap { terminal.terminal.getLine(row: $0)?.translateToString(trimRight: true) }
        }
    }

    /// The last line with anything on it: the command line, usually.
    var lastLine: String { screen.last { !$0.isEmpty } ?? "" }

    /// Runs a command and waits for the integration to report it finished.
    func run(_ command: String) async -> Bool {
        guard await waitForPrompt() else { return false }
        let finished = payloads(6973).filter { $0.hasPrefix("done;") }.count
        send(command + "\r")
        return await wait { payloads(6973).filter { $0.hasPrefix("done;") }.count > finished }
    }

    /// Waits until zsh is reading a command line: it has drawn a prompt (whose 133;B mark comes once
    /// its line editor has the terminal) after every command it ran. Typed sooner, keys go through the
    /// terminal's line mode, where DEL erases the byte before it, which can leave an escape sequence
    /// unfinished and the Return after it swallowed.
    func waitForPrompt() async -> Bool {
        await wait {
            payloads(133).filter { $0 == "B" }.count > payloads(6973).filter { $0.hasPrefix("exec;") }.count
        }
    }

    /// OSC payloads with this code, in arrival order.
    func payloads(_ code: Int) -> [String] {
        log.events.withLock { $0.filter { $0.code == code }.map { String(decoding: $0.payload, as: UTF8.self) } }
    }

    /// The columns the cursor was at when the 133;B marks arrived, in arrival order.
    var promptEndColumns: [Int] {
        log.events.withLock { $0.filter { $0.code == 133 && $0.payload == Array("B".utf8) }.map(\.cursor.col) }
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
        #expect(await zsh.wait { zsh.payloads(133).contains { $0.hasPrefix("A") } })
        let directories = zsh.payloads(7)
        #expect(directories.contains { $0.hasPrefix("file://") && $0.hasSuffix(zsh.home.path) })
    }

    @Test func reportsCommandsWithTheirStatusAndDuration() async throws {
        let zsh = try ZshHarness()
        #expect(await zsh.wait { zsh.payloads(133).contains { $0.hasPrefix("A") } })
        zsh.send("sleep 0.2; false\r")
        #expect(await zsh.wait { zsh.payloads(6973).contains { $0.hasPrefix("done;") } })

        let events = zsh.payloads(6973).compactMap(IntegrationEvent.init(payload:)).filter {
            if case .prompt = $0 { return false }
            if case .commandLineSelection = $0 { return false }
            if case .historyFile = $0 { return false }
            if case .toolchain = $0 { return false }
            return true
        }
        #expect(events.first == .commandStarted("sleep 0.2; false"))
        #expect(events.dropFirst().first == .commandText("sleep 0.2; false"))
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
        #expect(await zsh.wait { zsh.payloads(133).contains { $0.hasPrefix("A") } })
        zsh.send("mkdir -p 'with space' && cd 'with space'\r")
        #expect(await zsh.wait { zsh.payloads(6973).contains { $0.hasPrefix("done;") } })
        #expect(zsh.payloads(6973).last { $0.hasPrefix("done;") }?.hasPrefix("done;0;") == true)
        #expect(await zsh.wait { zsh.payloads(7).contains { $0.hasSuffix("/home/with%20space") } })
    }

    @Test func stillLoadsTheUsersStartupFiles() async throws {
        let zsh = try ZshHarness(homeFiles: [
            ".zshenv": "export CODEC_TEST_ENV=1\n",
            ".zshrc": "print -rn -- $'\\e]9999;zshrc-env='\"$CODEC_TEST_ENV\"$'\\a'\n",
        ])
        #expect(await zsh.wait { zsh.payloads(9999).contains("zshrc-env=1") })
        #expect(await zsh.wait { zsh.payloads(133).contains { $0.hasPrefix("A") } })
    }

    @Test func honorsACustomZdotdir() async throws {
        let config = try TemporaryDirectory()
        try config.file(".zshrc", "print -rn -- $'\\e]9999;custom-zdotdir\\a'\n")
        let zsh = try ZshHarness(zdotdir: config.url.path)
        #expect(await zsh.wait { zsh.payloads(9999).contains("custom-zdotdir") })
        zsh.send("print -rn -- $'\\e]9999;'\"$ZDOTDIR\"$'\\a'\r")
        #expect(await zsh.wait { zsh.payloads(9999).contains(config.url.path) })
    }

    /// Regression: Powerlevel10k moves its hook after Codec's at every prompt and builds PS1 anew there,
    /// so the prompts it drew had no 133;B mark and their line count was the previous prompt's.
    @Test func marksPromptsThemesBuildAfterCodecsHook() async throws {
        let zsh = try ZshHarness(homeFiles: [".zshrc": """
            _theme_precmd() {
              PROMPT="top"$'\\n''>> '
              [[ $precmd_functions[-1] == _theme_precmd ]] || precmd_functions=(${precmd_functions:#_theme_precmd} _theme_precmd)
            }
            precmd_functions+=(_theme_precmd)

            """])
        #expect(await zsh.waitForPrompt())
        #expect(await zsh.run("true"))
        #expect(await zsh.waitForPrompt())
        #expect(zsh.promptEndColumns.last == 3)
        #expect(zsh.payloads(6973).last { $0.hasPrefix("prompt;") } == "prompt;2")
    }

    /// Regression: redrawing the prompt (after switching branches, or saving a new prompt) ran the
    /// prompt hooks with $? set to 1, so prompts that show the last status showed a failure.
    @Test(arguments: [("true", 0), ("false", 1)])
    func redrawingThePromptKeepsTheLastStatus(command: String, status: Int) async throws {
        let zsh = try ZshHarness(homeFiles: [".zshrc": """
            _theme_precmd() { print -rn -- $'\\e]9999;status='$?$'\\a' >/dev/tty; PROMPT='%# ' }
            precmd_functions+=(_theme_precmd)

            """])
        #expect(await zsh.run(command))
        #expect(await zsh.waitForPrompt())
        let marks = zsh.promptEndColumns.count
        zsh.sendBytes(CommandLineEditing.Action.refreshPrompt.sequence)
        // The redrawn prompt is marked again, so Codec still knows where the command line starts.
        #expect(await zsh.wait { zsh.promptEndColumns.count > marks })
        #expect(zsh.payloads(9999).suffix(2) == ["status=\(status)", "status=\(status)"])
    }
}

/// Runs git in `directory`.
private func git(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "git \(arguments) failed"])
    }
}

private let gitAvailable = FileManager.default.isExecutableFile(atPath: "/Library/Developer/CommandLineTools/usr/bin/git")
    || FileManager.default.fileExists(atPath: "/Applications/Xcode.app")

@Suite("Codec prompt in zsh", .serialized, .timeLimit(.minutes(1)),
       .enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh") && gitAvailable))
struct ZshPromptTests {
    private var prompt: PromptConfiguration {
        var prompt = PromptConfiguration.default
        prompt.style = .codec
        prompt.layout = .singleLine
        prompt.blankLineBetweenCommands = false
        prompt.segments = [
            .init(.directory, enabled: true, color: .blue),
            .init(.gitBranch, enabled: true, color: .magenta),
            .init(.exitStatus, enabled: true, color: .red),
        ]
        return prompt
    }

    private func repository(in temp: TemporaryDirectory, branch: String) throws -> URL {
        let repo = try temp.directory("home/repo")
        try git(["init", "-q"], in: repo)
        try git(["symbolic-ref", "HEAD", "refs/heads/\(branch)"], in: repo)
        return repo
    }

    @Test func rendersSegmentsFromTheShellsState() async throws {
        let setup = try TemporaryDirectory()
        let repo = try repository(in: setup, branch: "feature/prompt")
        let zsh = try ZshHarness(homeFiles: [".zshrc": "PS1='USER> '\n"], prompt: prompt, directory: repo.path)
        #expect(await zsh.wait { zsh.payloads(133).contains { $0.hasPrefix("A") } })

        #expect(await zsh.run("false"))
        zsh.reportPrompt()
        #expect(await zsh.wait { !zsh.reportedPrompts.isEmpty })
        let afterFailure = try #require(zsh.reportedPrompts.last)
        #expect(afterFailure.contains("feature/prompt"))
        #expect(afterFailure.contains("✘ 1"))
        #expect(afterFailure.contains("%F{4}%~%f"))
        #expect(afterFailure.contains("❯"))

        #expect(await zsh.run("true"))
        zsh.reportPrompt()
        #expect(await zsh.wait { zsh.reportedPrompts.count == 2 })
        #expect(zsh.reportedPrompts.last?.contains("✘") == false)
    }

    @Test func appliesSettingsChangesToOpenShells() async throws {
        let zsh = try ZshHarness(homeFiles: [".zshrc": "PS1='USER> '\n"], prompt: prompt)
        #expect(await zsh.wait { zsh.payloads(133).contains { $0.hasPrefix("A") } })
        zsh.reportPrompt()
        #expect(await zsh.wait { zsh.reportedPrompts.count == 1 })
        #expect(zsh.reportedPrompts.last?.contains("❯") == true)

        var changed = prompt
        changed.symbol = "λ"
        try zsh.integration.writePrompt(changed)
        #expect(await zsh.run("true"))
        zsh.reportPrompt()
        #expect(await zsh.wait { zsh.reportedPrompts.count == 2 })
        #expect(zsh.reportedPrompts.last?.contains("λ") == true)

        try zsh.integration.writePrompt(.shellPrompt)
        #expect(await zsh.run("true"))
        zsh.reportPrompt()
        #expect(await zsh.wait { zsh.reportedPrompts.count == 3 })
        #expect(zsh.reportedPrompts.last?.hasPrefix("USER> ") == true)
    }

    @Test func showsGitChangeStatsDateAndTime() async throws {
        let setup = try TemporaryDirectory()
        let repo = try repository(in: setup, branch: "main")
        try "one\ntwo\nthree\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: repo)
        try git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "init"], in: repo)
        try "one\n2\nthree\nfour\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        var configuration = prompt
        configuration.segments = [
            .init(.gitDiffStats, enabled: true, color: .green),
            .init(.date, enabled: true, color: .green),
            .init(.time, enabled: true, color: .red),
        ]
        let zsh = try ZshHarness(prompt: configuration, directory: repo.path)
        #expect(await zsh.wait { zsh.payloads(133).contains { $0.hasPrefix("A") } })
        zsh.reportPrompt()
        #expect(await zsh.wait { !zsh.reportedPrompts.isEmpty })
        let rendered = try #require(zsh.reportedPrompts.last)
        #expect(rendered.contains("1 • +2 -1"), "\(rendered)")
        #expect(rendered.contains("%D{%b %d}"))
        #expect(rendered.contains("%D{%H:%M}"))
    }

    /// The prompt runs git before every command, so it must never lock the index against another app.
    @Test func readsGitWithoutRewritingTheIndex() async throws {
        let setup = try TemporaryDirectory()
        let repo = try repository(in: setup, branch: "main")
        let file = repo.appendingPathComponent("file.txt")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "."], in: repo)
        try git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "init"], in: repo)
        // The same contents with another date: `git diff` would refresh the index to record it.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: file.path)
        let index = repo.appendingPathComponent(".git/index")
        let before = try Data(contentsOf: index)

        var configuration = prompt
        configuration.showsGitChanges = true
        configuration.segments = [
            .init(.gitBranch, enabled: true, color: .magenta),
            .init(.gitDiffStats, enabled: true, color: .green),
        ]
        let zsh = try ZshHarness(prompt: configuration, directory: repo.path)
        #expect(await zsh.wait { zsh.payloads(133).contains { $0.hasPrefix("A") } })
        zsh.reportPrompt()
        #expect(await zsh.wait { !zsh.reportedPrompts.isEmpty })
        #expect(zsh.reportedPrompts.last?.contains("main") == true)
        #expect(try Data(contentsOf: index) == before)
    }

    /// The prompt zsh draws must match the Settings preview exactly.
    @Test(arguments: [true, false])
    func drawsExactlyWhatThePreviewShows(connectingWords: Bool) async throws {
        let setup = try TemporaryDirectory()
        let repo = try repository(in: setup, branch: "feature/prompt")
        var configuration = prompt
        configuration.appearance = .text
        configuration.connectingWords = connectingWords
        configuration.separator = " | "
        configuration.layout = connectingWords ? .twoLines : .singleLine
        configuration.showsGitChanges = false
        configuration.segments = [
            .init(.directory, enabled: true, color: .blue),
            .init(.gitBranch, enabled: true, color: .magenta),
            .init(.pythonEnvironment, enabled: true, color: .yellow),
            .init(.duration, enabled: true, color: .yellow),
            .init(.exitStatus, enabled: true, color: .red),
        ]
        // zsh reports the physical path (/private/var/…), so give it HOME in the same form.
        let home = realPath(repo.deletingLastPathComponent())
        let zsh = try ZshHarness(prompt: configuration, directory: repo.path,
                                 environment: ["VIRTUAL_ENV": "/opt/envs/venv", "HOME": home])
        #expect(await zsh.wait { zsh.payloads(133).contains { $0.hasPrefix("A") } })
        #expect(await zsh.run("false"))
        zsh.reportExpandedPrompt()
        #expect(await zsh.wait { !zsh.expandedPrompts.isEmpty })
        let drawn = try #require(zsh.expandedPrompts.last)

        var sample = PromptConfiguration.Sample()
        sample.home = home
        sample.directory = realPath(repo)
        sample.branch = "feature/prompt"
        sample.pythonEnvironment = "venv"
        sample.duration = 0
        sample.exitStatus = 1
        let preview = configuration.preview(sample).map(\.text).joined()
        #expect(drawn == preview)
        #expect(drawn == (connectingWords
            ? "~/repo on feature/prompt via venv ✘ 1\n\n❯ "
            : "~/repo | feature/prompt | (venv) | ✘ 1 ❯ "))
    }

    /// Chips: pills with rounded caps, filled with the theme's tint, matching the preview.
    @Test func drawsChipsExactlyAsThePreviewShows() async throws {
        let setup = try TemporaryDirectory()
        let repo = try repository(in: setup, branch: "feature/prompt")
        var configuration = prompt
        configuration.appearance = .chips
        configuration.layout = .twoLines
        configuration.showsGitChanges = false
        configuration.segments = [
            .init(.directory, enabled: true, color: .blue),
            .init(.gitBranch, enabled: true, color: .magenta),
            .init(.exitStatus, enabled: true, color: .red),
        ]
        let home = realPath(repo.deletingLastPathComponent())
        let zsh = try ZshHarness(directory: repo.path, environment: ["HOME": home])
        try zsh.integration.writePrompt(configuration, chipFills: [.blue: "#102a40", .magenta: "#2a1040", .red: "#401010"])
        #expect(await zsh.wait { zsh.payloads(133).contains { $0.hasPrefix("A") } })
        #expect(await zsh.run("false"))
        zsh.reportExpandedPrompt()
        #expect(await zsh.wait { !zsh.expandedPrompts.isEmpty })
        let drawn = try #require(zsh.expandedPrompts.last)
        #expect(drawn == "\u{E0B6} ~/repo \u{E0B4} \u{E0B6} ⎇ feature/prompt \u{E0B4} \u{E0B6} ✘ 1 \u{E0B4}\n\n❯ ")

        var sample = PromptConfiguration.Sample()
        sample.home = home
        sample.directory = realPath(repo)
        sample.branch = "feature/prompt"
        sample.duration = 0
        sample.exitStatus = 1
        let withoutCaps = drawn.replacingOccurrences(of: "\u{E0B6} ", with: "").replacingOccurrences(of: " \u{E0B4}", with: "")
        #expect(withoutCaps == configuration.preview(sample).map(\.text).joined())

        // The pill is the theme's fill, in true color: #102a40 → 16;42;64.
        let raw = try #require(zsh.rawExpandedPrompts.last)
        #expect(raw.contains("\u{1b}[48;2;16;42;64m"))
    }

    /// zsh and the terminal must agree on how wide the chips are, or the cursor drifts while editing.
    @Test func cursorLandsWhereZshExpectsAfterTheChips() async throws {
        let setup = try TemporaryDirectory()
        let repo = try repository(in: setup, branch: "main")
        var configuration = prompt
        configuration.appearance = .chips
        configuration.layout = .singleLine
        configuration.blankLineBetweenCommands = false
        configuration.segments = [.init(.directory, enabled: true, color: .blue), .init(.gitBranch, enabled: true, color: .magenta)]
        // A short "~/repo" keeps the prompt on one line of the 80-column terminal.
        let zsh = try ZshHarness(prompt: configuration, directory: repo.path,
                                 environment: ["HOME": realPath(repo.deletingLastPathComponent())])
        #expect(await zsh.wait { zsh.payloads(133).contains { $0.hasPrefix("A") } })
        // Successful commands in the same place draw the same prompt each time, so the reported prompt
        // is also the one on screen afterwards.
        #expect(await zsh.run("true"))
        zsh.reportExpandedPrompt()
        #expect(await zsh.wait { !zsh.expandedPrompts.isEmpty })
        let width = try #require(zsh.expandedPrompts.last).count
        #expect(width > 10 && width < 80)
        let landed = await zsh.wait { zsh.cursor.x == width }
        #expect(landed, "cursor at column \(zsh.cursor.x), but zsh drew a prompt \(width) columns wide")
    }

    @Test func separatesCommandsWithABlankLine() async throws {
        var configuration = prompt
        configuration.appearance = .text
        configuration.blankLineBetweenCommands = true
        configuration.segments = [.init(.directory, enabled: true, color: .blue)]
        let zsh = try ZshHarness(prompt: configuration)
        #expect(await zsh.wait { zsh.payloads(133).contains { $0.hasPrefix("A") } })
        #expect(await zsh.run("true"))
        zsh.reportExpandedPrompt()
        #expect(await zsh.wait { !zsh.expandedPrompts.isEmpty })
        #expect(zsh.expandedPrompts.last == "\n~ ❯ ")
    }

    /// Regression: with prompt_subst on, a hostile branch name must not run code when the prompt is drawn.
    @Test func neverRunsCodeFromBranchNames() async throws {
        let setup = try TemporaryDirectory()
        let repo = try repository(in: setup, branch: "$(touch${IFS}pwned)")
        let zsh = try ZshHarness(homeFiles: [".zshrc": "setopt prompt_subst\n"], prompt: prompt, directory: repo.path)
        #expect(await zsh.wait { zsh.payloads(133).contains { $0.hasPrefix("A") } })
        // The first prompt has been drawn once a command has run after it.
        #expect(await zsh.run("true"))
        #expect(await zsh.run("true"))
        zsh.reportPrompt()
        #expect(await zsh.wait { !zsh.reportedPrompts.isEmpty })
        #expect(zsh.reportedPrompts.last?.contains(#"\$(touch"#) == true)
        #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent("pwned").path))
    }
}

/// The physical path, with symlinks such as /var → /private/var resolved the way the kernel reports it.
private func realPath(_ url: URL) -> String {
    guard let resolved = realpath(url.path, nil) else { return url.path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Typing, selecting and deleting on the command line, the way Codec drives it, in a real zsh.
@Suite("Command line editing in zsh", .serialized, .timeLimit(.minutes(1)),
       .enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")))
struct CommandLineEditingTests {
    typealias Action = CommandLineEditing.Action

    private func shell(rc: String = "") async throws -> ZshHarness {
        let zsh = try ZshHarness(homeFiles: [".zshrc": rc])
        #expect(await zsh.waitForPrompt())
        return zsh
    }

    /// Types `text`, applies `keys`, presses Return, and gives back the command zsh ran.
    private func run(_ zsh: ZshHarness, typing text: String, then keys: [UInt8]) async -> String? {
        guard await zsh.waitForPrompt() else { return nil }
        let before = zsh.payloads(6973).count
        zsh.send(text)
        zsh.sendBytes(keys)
        zsh.send("\r")
        guard await zsh.wait(until: { zsh.payloads(6973).dropFirst(before).contains { $0.hasPrefix("exec;") } }) else { return nil }
        return zsh.payloads(6973).dropFirst(before).first { $0.hasPrefix("exec;") }.map { String($0.dropFirst(5)) }
    }

    @Test func draggingSelectsFromTheAnchor() async throws {
        let zsh = try await shell()
        // Press 5 cells left of the end ("world" starts there), drag right past it, then back to 3.
        let keys = CommandLineEditing.press(at: -5) + CommandLineEditing.drag(to: 9) + CommandLineEditing.drag(to: 3) + [0x7F]
        #expect(await run(zsh, typing: "echo hello world", then: keys) == "echo hello ld")
    }

    @Test func copyAndCutHandTheSelectionToCodec() async throws {
        let zsh = try await shell()
        zsh.send("echo hello world")
        zsh.sendBytes(CommandLineEditing.select(from: -5, to: 0) + Action.copy.sequence)
        #expect(await zsh.wait { zsh.payloads(6973).contains("clipboard;d29ybGQ=") })
        #expect(zsh.payloads(6973).contains("region;1"))
        zsh.sendBytes(CommandLineEditing.select(from: -11, to: -6) + Action.cut.sequence)
        #expect(await zsh.wait { zsh.payloads(6973).contains("clipboard;aGVsbG8=") })
        #expect(await zsh.wait { zsh.payloads(6973).last { $0.hasPrefix("region;") } == "region;0" })
        let before = zsh.payloads(6973).count
        zsh.send("\r")
        #expect(await zsh.wait { zsh.payloads(6973).dropFirst(before).contains("exec;echo  world") })
    }

    @Test func advertisesClickToMove() async throws {
        let zsh = try await shell()
        #expect(zsh.payloads(133).contains("A;cl=line"))
    }

    @Test func deletingRemovesTheSelection() async throws {
        let zsh = try await shell()
        let command = await run(zsh, typing: "echo hello world", then: CommandLineEditing.select(from: -5, to: 0) + [0x7F])
        #expect(command == "echo hello ")
    }

    @Test func typingReplacesTheSelection() async throws {
        let zsh = try await shell()
        let command = await run(zsh, typing: "echo hello world", then: CommandLineEditing.select(from: -11, to: -6) + Array("bye".utf8))
        #expect(command == "echo bye world")
    }

    @Test func forwardDeleteRemovesTheSelection() async throws {
        let zsh = try await shell()
        let command = await run(zsh, typing: "echo abcdef", then: CommandLineEditing.select(from: -3, to: -1) + Array("\u{1b}[3~".utf8))
        #expect(command == "echo abcf")
    }

    @Test func shiftArrowsExtendTheSelection() async throws {
        let zsh = try await shell()
        let shiftLeft = Array("\u{1b}[1;2D".utf8)
        let command = await run(zsh, typing: "echo abc", then: shiftLeft + shiftLeft + shiftLeft + Array("X".utf8))
        #expect(command == "echo X")
    }

    @Test func plainArrowsEndTheSelection() async throws {
        let zsh = try await shell()
        let shiftLeft = Array("\u{1b}[1;2D".utf8), left = Array("\u{1b}[D".utf8)
        let command = await run(zsh, typing: "echo abc", then: shiftLeft + shiftLeft + shiftLeft + left + Array("X".utf8))
        #expect(command == "echoX abc")
    }

    @Test func selectsAWordAndCutsIt() async throws {
        let zsh = try await shell()
        let keys = CommandLineEditing.steps(-6) + Action.selectWord.sequence + Action.cut.sequence
        let command = await run(zsh, typing: "ls /usr/local/bin now", then: keys)
        #expect(command == "ls  now")
    }

    @Test func selectAllThenTypeReplacesTheCommand() async throws {
        let zsh = try await shell()
        let command = await run(zsh, typing: "echo old", then: Action.selectAll.sequence + Array("echo new".utf8))
        #expect(command == "echo new")
    }

    @Test func movesAndDeletesToTheStartOfTheLine() async throws {
        let zsh = try await shell()
        #expect(await run(zsh, typing: "cho one", then: Action.moveToStart.sequence + Array("e".utf8)) == "echo one")
        #expect(await run(zsh, typing: "echo one two", then: CommandLineEditing.steps(-3) + Action.deleteToStart.sequence) == "two")
        let selectToEnd = Action.moveToStart.sequence + Action.selectToEnd.sequence + Array("pwd".utf8)
        #expect(await run(zsh, typing: "echo gone", then: selectToEnd) == "pwd")
    }

    /// Selections clamp to the command line: a drag that starts over the prompt selects from its start,
    /// and one that ends past the text selects to its end, without moving the other edge.
    @Test func selectionsClampToTheCommandLine() async throws {
        let zsh = try await shell()
        #expect(await run(zsh, typing: "echo x", then: CommandLineEditing.select(from: -40, to: -2) + Array("pwd ".utf8)) == "pwd  x")
        // Cursor at index 2 of "echo abc"; 3 → 30 selects index 5 to the end: "abc".
        #expect(await run(zsh, typing: "echo abc", then: CommandLineEditing.steps(-6) + CommandLineEditing.select(from: 3, to: 30)
                          + [0x7F]) == "echo ")
    }

    /// Plugins wrap self-insert too; their wrapper must keep running, and selections still replace.
    @Test func keepsWidgetsWrappedByPlugins() async throws {
        let rc = #"""
        typeset -gi PLUGIN_CALLS=0
        plugin_self_insert() { (( PLUGIN_CALLS++ )); zle .self-insert }
        zle -N self-insert plugin_self_insert
        """#
        let zsh = try await shell(rc: rc)
        let command = await run(zsh, typing: "echo hello", then: CommandLineEditing.select(from: -5, to: 0) + Array("bye".utf8))
        #expect(command == "echo bye")
        zsh.send(#"print -rn -- $'\e]9999;calls='$PLUGIN_CALLS$'\a'"# + "\r")
        #expect(await zsh.wait { zsh.payloads(9999).contains { $0.hasPrefix("calls=") } })
        let calls = zsh.payloads(9999).first { $0.hasPrefix("calls=") }.flatMap { Int($0.dropFirst(6)) } ?? 0
        #expect(calls >= "echo hello".count + "bye".count)
    }
}

@Suite("History and completion in zsh", .serialized, .timeLimit(.minutes(1)),
       .enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")))
struct HistoryAndCompletionTests {
    private static let features = ["CODEC_SUGGESTIONS": "1", "CODEC_HISTORY_KEYS": "1", "CODEC_COMPLETION": "1"]

    /// A short prompt comes first: macOS's default one has the host name, and a long one (as CI runners
    /// have) wraps what's typed onto the next line.
    private func shell(rc: String = "", environment: [String: String] = features, directory: String? = nil) async throws -> ZshHarness {
        let zsh = try ZshHarness(homeFiles: [".zshrc": "PS1='%# '\n" + rc], directory: directory, environment: environment)
        #expect(await zsh.waitForPrompt())
        return zsh
    }

    private func ranCommand(_ zsh: ZshHarness, after before: Int) async -> String? {
        guard await zsh.wait(until: { zsh.payloads(6973).dropFirst(before).contains { $0.hasPrefix("exec;") } }) else { return nil }
        return zsh.payloads(6973).dropFirst(before).first { $0.hasPrefix("exec;") }.map { String($0.dropFirst(5)) }
    }

    @Test func reportsTheWholeCommandAndTheHistoryFile() async throws {
        let zsh = try await shell(rc: "HISTFILE=$HOME/.zsh_history")
        #expect(zsh.payloads(6973).contains { $0.hasPrefix("histfile;") && $0.hasSuffix("/.zsh_history") })
        #expect(await zsh.run("echo one; \\\necho two"))
        let encoded = zsh.payloads(6973).first { $0.hasPrefix("command;") }.map { String($0.dropFirst(8)) }
        let text = encoded.flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }
        #expect(text == "echo one; \\\necho two")
    }

    @Test func suggestsFromHistoryAndTakesItWithTheRightArrow() async throws {
        let zsh = try await shell()
        #expect(await zsh.run("echo codec-suggestion-42"))
        zsh.send("echo codec-s")
        #expect(await zsh.wait { zsh.lastLine.hasSuffix("echo codec-suggestion-42") })
        let before = zsh.payloads(6973).count
        zsh.send("\u{1b}[C\r")
        #expect(await ranCommand(zsh, after: before) == "echo codec-suggestion-42")
    }

    @Test func optionRightTakesOneWord() async throws {
        let zsh = try await shell()
        #expect(await zsh.run("echo alpha beta gamma"))
        zsh.send("echo al")
        #expect(await zsh.wait { zsh.lastLine.hasSuffix("echo alpha beta gamma") })
        let before = zsh.payloads(6973).count
        // ⌥→ with Option as Meta: ESC f, forward-word.
        zsh.send("\u{1b}f\r")
        #expect(await ranCommand(zsh, after: before) == "echo alpha")
    }

    @Test func noSuggestionWhenTurnedOff() async throws {
        let zsh = try await shell(environment: [:])
        #expect(await zsh.run("echo nothing-to-see"))
        zsh.send("echo noth")
        #expect(await zsh.wait { zsh.lastLine.hasSuffix("echo noth") })
        try await Task.sleep(for: .milliseconds(300))
        #expect(zsh.lastLine.hasSuffix("echo noth"))
    }

    @Test func upArrowAndControlRAskCodec() async throws {
        let zsh = try await shell()
        zsh.send("git st")
        zsh.send("\u{1b}[A")
        #expect(await zsh.wait { zsh.payloads(6973).contains("history;menu;" + Data("git st".utf8).base64EncodedString()) })
        zsh.send("\u{12}")
        #expect(await zsh.wait { zsh.payloads(6973).contains("history;search;" + Data("git st".utf8).base64EncodedString()) })
    }

    @Test func keysTheUserReboundAreLeftAlone() async throws {
        let zsh = try await shell(rc: "bindkey '^R' clear-screen")
        zsh.send("\u{12}")
        try await Task.sleep(for: .milliseconds(400))
        #expect(!zsh.payloads(6973).contains { $0.hasPrefix("history;search") })
    }

    @Test func pastingReplacesWhatWasTyped() async throws {
        let zsh = try await shell()
        zsh.send("old text")
        let before = zsh.payloads(6973).count
        zsh.sendBytes(CommandLineEditing.Action.selectAll.sequence + Array("\u{1b}[200~echo pasted\u{1b}[201~\r".utf8))
        #expect(await ranCommand(zsh, after: before) == "echo pasted")
    }

    @Test func tabCompletesIgnoringCaseAndInsideNames() async throws {
        let temp = try TemporaryDirectory()
        let folder = try temp.directory("work")
        try temp.directory("work/Development")
        try temp.file("work/my-notes.txt", "")
        let zsh = try await shell(directory: folder.path)
        var before = zsh.payloads(6973).count
        zsh.send("ls dev\t")
        try await Task.sleep(for: .milliseconds(500))
        zsh.send("\r")
        let ran = await ranCommand(zsh, after: before)
        #expect(ran?.hasPrefix("ls Development") == true)

        before = zsh.payloads(6973).count
        zsh.send("cat notes\t")
        try await Task.sleep(for: .milliseconds(500))
        zsh.send("\r")
        #expect(await ranCommand(zsh, after: before)?.trimmingCharacters(in: .whitespaces) == "cat my-notes.txt")
    }

    @Test func leavesTheUsersCompletionStylesAlone() async throws {
        let zsh = try await shell(rc: "autoload -Uz compinit && compinit -u\nzstyle ':completion:*' matcher-list ''")
        let before = zsh.payloads(9999).count
        zsh.send(#"print -rn -- $'\e]9999;'"$(zstyle -L ':completion:*' matcher-list)"$'\a'"# + "\r")
        #expect(await zsh.wait { zsh.payloads(9999).count > before })
        #expect(zsh.payloads(9999).last == "zstyle ':completion:*' matcher-list ''")
    }
}


@Suite("Python environments in zsh", .serialized, .timeLimit(.minutes(1)),
       .enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")))
struct VenvActivationTests {
    /// A shell in a home with a project holding a virtual environment, `~/app/.venv`.
    private func shell(rc: String = "", venv: Bool = true, environment: [String: String] = [:]) async throws -> (ZshHarness, String) {
        let zsh = try ZshHarness(homeFiles: [".zshrc": "PS1='%# '\n" + rc, "app/.venv/pyvenv.cfg": "version_info = 3.14.6\nprompt = app\n",
                                             "app/src/.keep": ""],
                                 environment: ["CODEC_VENV": venv ? "1" : "0"].merging(environment) { _, new in new })
        #expect(await zsh.waitForPrompt())
        return (zsh, realPath(zsh.home) + "/app/.venv")
    }

    /// The toolchain reports, without the variables, which most tests don't look at.
    private func reports(_ zsh: ZshHarness, variables: Bool = false) -> [ToolchainReport] {
        zsh.payloads(6973).compactMap(IntegrationEvent.init(payload:)).compactMap { event in
            guard case .toolchain(var report) = event else { return nil }
            if !variables { report.environment = [:] }
            return report
        }
    }

    /// Runs a command, then waits for the toolchain report it leads to (or for the prompt, when nothing changed).
    /// The report comes before the prompt's line count, which is what's waited for: not `waitForPrompt`,
    /// which a prompt redrawn by a widget (Codec's refresh, This Time) satisfies one prompt early.
    private func run(_ zsh: ZshHarness, _ command: String) async -> ToolchainReport? {
        let before = zsh.payloads(6973).count
        #expect(await zsh.run(command))
        #expect(await zsh.wait {
            let new = zsh.payloads(6973).dropFirst(before)
            guard let done = new.lastIndex(where: { $0.hasPrefix("done;") }) else { return false }
            return new[done...].contains { $0.hasPrefix("prompt;") }
        })
        return reports(zsh).last
    }

    /// The first folder on the shell's PATH.
    private func firstOnPath(_ zsh: ZshHarness) async -> String? {
        let before = zsh.payloads(9999).count
        zsh.send(#"print -rn -- $'\e]9999;'"$path[1]"$'\a'"# + "\r")
        guard await zsh.wait(until: { zsh.payloads(9999).count > before }) else { return nil }
        #expect(await zsh.waitForPrompt())
        return zsh.payloads(9999).last
    }

    @Test func asksOnceThenActivatesOnTheWayInAndDeactivatesOnTheWayOut() async throws {
        let (zsh, venv) = try await shell()
        // Below the project too.
        #expect(await run(zsh, "cd app/src") == ToolchainReport(pending: venv))
        #expect(await firstOnPath(zsh) != venv + "/bin")

        try zsh.integration.venvDecisions.set(.allow, for: venv)
        // Codec redraws the prompt once the user answered.
        zsh.sendBytes(CommandLineEditing.Action.refreshPrompt.sequence)
        #expect(await zsh.wait { reports(zsh).last == ToolchainReport(virtualEnv: venv, activatedByCodec: true) })
        #expect(await firstOnPath(zsh) == venv + "/bin")

        #expect(await run(zsh, "cd /") == ToolchainReport())
        #expect(await firstOnPath(zsh) != venv + "/bin")
        // Back in, without asking.
        #expect(await run(zsh, "cd ~/app") == ToolchainReport(virtualEnv: venv, activatedByCodec: true))
    }

    @Test func activatesThisTimeOnlyUntilYouLeave() async throws {
        let (zsh, venv) = try await shell()
        #expect(await run(zsh, "cd app") == ToolchainReport(pending: venv))
        zsh.sendBytes(CommandLineEditing.Action.activateVenvOnce.sequence)
        #expect(await zsh.wait { reports(zsh).last == ToolchainReport(virtualEnv: venv, activatedByCodec: true) })
        #expect(await firstOnPath(zsh) == venv + "/bin")
        #expect(await run(zsh, "cd src") == ToolchainReport(virtualEnv: venv, activatedByCodec: true))
        // Nothing was remembered: gone on the way out, asked about again on the way back.
        #expect(await run(zsh, "cd /") == ToolchainReport())
        #expect(await run(zsh, "cd ~/app") == ToolchainReport(pending: venv))
        #expect(zsh.integration.venvDecisions.entries.isEmpty)
    }

    @Test func activatesInTheSameCommandLineAsTheCd() async throws {
        let (zsh, venv) = try await shell()
        try zsh.integration.venvDecisions.set(.allow, for: venv)
        zsh.send(#"cd app && print -rn -- $'\e]9999;'"$VIRTUAL_ENV"$'\a'"# + "\r")
        #expect(await zsh.wait { zsh.payloads(9999).last == venv })
    }

    @Test func deactivateKeepsItOffUntilYouLeave() async throws {
        let (zsh, venv) = try await shell()
        try zsh.integration.venvDecisions.set(.allow, for: venv)
        #expect(await run(zsh, "cd app")?.virtualEnv == venv)
        #expect(await run(zsh, "deactivate") == ToolchainReport())
        #expect(await run(zsh, "cd src") == ToolchainReport())
        #expect(await run(zsh, "cd /tmp && cd ~/app") == ToolchainReport(virtualEnv: venv, activatedByCodec: true))
    }

    @Test func leavesOtherEnvironmentsAlone() async throws {
        let (zsh, venv) = try await shell()
        try zsh.integration.venvDecisions.set(.allow, for: venv)
        #expect(await run(zsh, "export VIRTUAL_ENV=/elsewhere/.venv; cd app") == ToolchainReport(virtualEnv: "/elsewhere/.venv"))
        // Theirs gone, the project's own is activated.
        #expect(await run(zsh, "unset VIRTUAL_ENV") == ToolchainReport(virtualEnv: venv, activatedByCodec: true))
        // The project's, activated by hand: deactivated by hand, Codec doesn't bring it back while here.
        #expect(await run(zsh, "deactivate; cd /; export VIRTUAL_ENV=$HOME/app/.venv; cd ~/app") == ToolchainReport(virtualEnv: venv))
        #expect(await run(zsh, "unset VIRTUAL_ENV") == ToolchainReport())
    }

    @Test func refusedOrTurnedOffItNeverActivates() async throws {
        let (zsh, venv) = try await shell()
        try zsh.integration.venvDecisions.set(.deny, for: venv)
        #expect(await run(zsh, "cd app") == ToolchainReport())

        let (off, _) = try await shell(venv: false)
        #expect(await run(off, "cd app") == ToolchainReport())
    }

    @Test func refusingLaterTurnsItOff() async throws {
        let (zsh, venv) = try await shell()
        try zsh.integration.venvDecisions.set(.allow, for: venv)
        #expect(await run(zsh, "cd app")?.virtualEnv == venv)
        try zsh.integration.venvDecisions.set(.deny, for: venv)
        zsh.sendBytes(CommandLineEditing.Action.refreshPrompt.sequence)
        #expect(await zsh.wait { reports(zsh).last == ToolchainReport() })
    }

    @Test func reportsOtherVersionManagersAndTheirVariables() async throws {
        let (zsh, _) = try await shell(rc: """
            path=($HOME/bin $path)
            nvm() { :; }
            export NVM_BIN=$HOME/.nvm/versions/node/v20.11.0/bin

            """)
        try zsh.temp.file("home/bin/pyenv", "#!/bin/sh\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: zsh.home.appendingPathComponent("bin/pyenv").path)
        #expect(await run(zsh, "rehash; cd app") != nil)
        let variables = try #require(reports(zsh, variables: true).last).environment
        #expect(variables["PWD"] == realPath(zsh.home) + "/app")
        #expect(variables["managers"] == "pyenv nvm")
        #expect(variables["NVM_BIN"] == realPath(zsh.home) + "/.nvm/versions/node/v20.11.0/bin")
        // `pyenv local` writes a version file: what it changed is reported.
        let count = reports(zsh).count
        #expect(await zsh.run("pyenv local 3.12"))
        #expect(await zsh.wait { reports(zsh).count == count + 1 })
        #expect(await run(zsh, "export PYENV_VERSION=3.13") != nil)
        #expect(reports(zsh, variables: true).last?.environment["PYENV_VERSION"] == "3.13")
    }

    @Test func reportsMisesToolsOnlyWhenTheyMayHaveChanged() async throws {
        let json = #"{"ruby":[{"version":"4.0.2","installed":true}]}"#
        let (zsh, _) = try await shell(rc: """
            path=($HOME/bin $path)
            _mise_hook() { :; }

            """, environment: [:])
        try zsh.temp.file("home/bin/mise", "#!/bin/sh\necho '\(json)'\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: zsh.home.appendingPathComponent("bin/mise").path)
        // Changing folders looks again.
        #expect(await run(zsh, "rehash; cd /tmp")?.mise.contains("4.0.2") == true)
        let count = reports(zsh).count
        #expect(await zsh.run("true"))
        #expect(await zsh.waitForPrompt())
        #expect(reports(zsh).count == count)
        // So does running mise.
        #expect(await zsh.run("mise --version >/dev/null"))
        #expect(await zsh.wait { reports(zsh).count == count + 1 })
    }
}

@Suite("Listing files in zsh", .serialized, .timeLimit(.minutes(1)),
       .enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")))
struct ListingTests {
    /// A zsh whose PATH has a stand-in eza, when `eza` is true, and otherwise only the system's
    /// folders, so an eza installed on this Mac isn't found. The .zshrc sets it, as a user's would.
    private func shell(rc: String = "", eza: Bool = true, setting: Bool = true) async throws -> ZshHarness {
        let path = eza ? "chmod +x ~/bin/eza; path=(~/bin $path)\n" : "path=(/usr/bin /bin)\n"
        let zsh = try ZshHarness(homeFiles: [".zshrc": "PS1='%# '\n" + path + rc, "bin/eza": "#!/bin/sh\necho eza \"$@\"\n"],
                                 environment: ["CODEC_EZA": setting ? "1" : "0"])
        #expect(await zsh.waitForPrompt())
        return zsh
    }

    private func lsAlias(_ zsh: ZshHarness) async -> String? {
        let before = zsh.payloads(9999).count
        zsh.send(#"print -rn -- $'\e]9999;ls='"${aliases[ls]}"$'\a'"# + "\r")
        guard await zsh.wait(until: { zsh.payloads(9999).count > before }) else { return nil }
        return zsh.payloads(9999).last.map { String($0.dropFirst(3)) }
    }

    @Test func lsRunsEzaWithIcons() async throws {
        #expect(await lsAlias(try await shell()) == "eza --icons=auto --group-directories-first")
    }

    @Test func replacesAnAliasThatOnlyTurnsOnColor() async throws {
        #expect(await lsAlias(try await shell(rc: "alias ls='ls -G'")) == "eza --icons=auto --group-directories-first")
    }

    @Test func leavesTheUsersOwnLsAlone() async throws {
        #expect(await lsAlias(try await shell(rc: "alias ls='ls -lah'")) == "ls -lah")
    }

    @Test func doesNothingWithoutEzaOrTheSetting() async throws {
        #expect(await lsAlias(try await shell(eza: false)) == "")
        #expect(await lsAlias(try await shell(setting: false)) == "")
    }
}
