import Testing
import Foundation
import AppKit
import SwiftUI
import CodecCore
@testable import CodecUI

/// Python environments and tool versions: asking whether to activate a project's `.venv`, and showing
/// what's in effect.
@Suite("Project environments", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ToolchainUITests {
    private func report(pending: String? = nil, virtualEnv: String? = nil) -> IntegrationEvent {
        .toolchain(ToolchainReport(virtualEnv: virtualEnv, activatedByCodec: virtualEnv != nil, pending: pending))
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")))
    func asksThenActivatesAndRemembersWhatCommandsRanWith() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        try "version_info = 3.14.6\nprompt = demo\n"
            .write(to: try makeVenv(in: env.directory.appendingPathComponent("demo")), atomically: true, encoding: .utf8)
        let config = env.directory.appendingPathComponent("zdotdir")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "PS1='%# '\n".write(to: config.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        setenv("ZDOTDIR", config.path, 1)
        let controller = TerminalWindowController(directory: env.directory.path, environment: env.environment)
        unsetenv("ZDOTDIR")
        defer {
            controller.model.tabs.flatMap(\.panes).forEach { $0.shutDown() }
            controller.window?.close()
        }
        let pane = try #require(controller.model.selected?.focused)
        #expect(await waitUntil { pane.isAtCommandLine })
        // Nothing to ask: the banner takes no room, so it takes no clicks from the terminal.
        pane.view.layoutSubtreeIfNeeded()
        #expect(pane.view.venvBanner.frame.size == .zero)

        pane.terminal.send(txt: "cd demo\r")
        #expect(await waitUntil { pane.session.pendingVenv != nil })
        let venv = try #require(pane.session.pendingVenv)
        #expect(venv.path.hasSuffix("/demo/.venv"))
        #expect(venv.label == "demo")
        #expect(venv.version == "3.14.6")
        // The question shows at the top of the pane, and only takes that much of it.
        pane.view.layoutSubtreeIfNeeded()
        #expect(pane.view.venvBanner.frame.height > 20)
        #expect(pane.view.venvBanner.frame.height < pane.view.bounds.height / 2)

        pane.decide(venv, .allow)
        #expect(env.environment.shellIntegration?.venvDecisions.decision(for: venv.path) == .allow)
        #expect(await waitUntil { pane.session.toolchain.python?.activatedByCodec == true })
        #expect(pane.session.pendingVenv == nil)
        #expect(pane.session.toolchain.python?.path == venv.path)
        pane.view.layoutSubtreeIfNeeded()
        #expect(pane.view.venvBanner.frame.size == .zero)

        pane.terminal.send(txt: "true\r")
        #expect(await waitUntil { pane.timeline.entries.count == 2 && pane.timeline.running == nil })
        #expect(pane.timeline.entries[0].toolchain?.python == nil)
        #expect(pane.timeline.entries[1].toolchain?.python?.path == venv.path)

        // The Commands sidebar starts a new heading where the environment changed.
        controller.toggleCommandTimeline(nil)
        let headings = controller.timelineSidebar.rows.compactMap { row -> Toolchain?? in
            if case .directory(_, let toolchain) = row { return toolchain }
            return nil
        }
        #expect(headings.count == 2)
        #expect(headings.last??.python?.label == "demo")
    }

    private func makeVenv(in project: URL) throws -> URL {
        let venv = project.appendingPathComponent(".venv")
        try FileManager.default.createDirectory(at: venv, withIntermediateDirectories: true)
        return venv.appendingPathComponent("pyvenv.cfg")
    }

    @Test func anAnswerReachesEveryPaneAskingAboutTheSameEnvironment() throws {
        let env = try TestEnvironment(integration: true)
        defer { env.tearDown() }
        let first = env.makePane(), second = env.makePane(), other = env.makePane()
        defer { [first, second, other].forEach { $0.shutDown() } }
        first.handle(report(pending: "/code/app/.venv"))
        second.handle(report(pending: "/code/app/.venv"))
        other.handle(report(pending: "/code/other/.venv"))
        let venv = try #require(first.session.pendingVenv)
        #expect(venv.label == "app")

        first.decide(venv, .deny)
        #expect(env.environment.shellIntegration?.venvDecisions.decision(for: "/code/app/.venv") == .deny)
        #expect(first.session.pendingVenv == nil)
        #expect(second.session.pendingVenv == nil)
        #expect(other.session.pendingVenv?.path == "/code/other/.venv")
    }

    @Test func notNowOnlyQuietsThisPane() throws {
        let env = try TestEnvironment(integration: true)
        defer { env.tearDown() }
        let first = env.makePane(), second = env.makePane()
        defer { [first, second].forEach { $0.shutDown() } }
        first.handle(report(pending: "/code/app/.venv"))
        second.handle(report(pending: "/code/app/.venv"))
        first.decide(try #require(first.session.pendingVenv), nil)
        #expect(first.session.pendingVenv == nil)
        #expect(second.session.pendingVenv != nil)
        #expect(env.environment.shellIntegration?.venvDecisions.decision(for: "/code/app/.venv") == nil)
        // The shell asks again at the next prompt; this pane doesn't.
        first.handle(report(pending: "/code/app/.venv"))
        #expect(first.session.pendingVenv == nil)
    }

    @Test func panesTellTheShellWhetherToActivate() throws {
        let env = try TestEnvironment(integration: true)
        defer { env.tearDown() }
        let pane = env.makePane()
        defer { pane.shutDown() }
        #expect(pane.shellEnvironment(shell: "/bin/zsh")["CODEC_VENV"] == "1")
        #expect(pane.shellEnvironment(shell: "/bin/zsh")["CODEC_VENV_DECISIONS"]?.hasSuffix("/venv-decisions") == true)
        env.preferences.activateVenvs = false
        #expect(pane.shellEnvironment(shell: "/bin/zsh")["CODEC_VENV"] == "0")
    }

    @Test func statusBarShowsTheEnvironmentOnlyWhenThereIsOne() throws {
        _ = NSApplication.shared
        let session = Session()
        let host = NSHostingView(rootView: ToolchainStatus(session: session, theme: .codec, run: { _ in true }))
        #expect(host.fittingSize.width == 0)
        session.toolchain = Toolchain(python: .init(path: "/code/demo/.venv", version: "3.14.6"),
                                      tools: [.init(name: "ruby", version: "4.0.2"), .init(name: "node", version: "22.1.0", requested: "22", installed: false)])
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 150)
    }

    @Test func commandsHeadingShowsTheVersions() {
        let cell = TimelineDirectoryCell()
        cell.show("~/code/demo", theme: .codec)
        #expect(cell.shown.tools == nil)
        let toolchain = Toolchain(python: .init(path: "/code/demo/.venv", version: "3.14.6"),
                                  tools: [.init(name: "node", version: "22.1.0", requested: "22", installed: false)])
        cell.show("~/code/demo", toolchain: toolchain, theme: .codec)
        #expect(cell.shown.directory == "~/code/demo")
        #expect(cell.shown.tools == "py 3.14.6 · node 22!")
        #expect(cell.toolTip == "~/code/demo\npython 3.14.6 (demo) · node 22.1.0 (not installed)")
    }
}
