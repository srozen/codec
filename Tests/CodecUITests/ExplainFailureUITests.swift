import Testing
import Foundation
import AppKit
import CodecCore
@testable import CodecUI

/// Writes a canned explanation in two steps, the way the model streams one.
struct FakeExplainer: FailureExplaining {
    var availability: ExplainerAvailability = .available
    var explanation = FailureExplanation(cause: "There's no such folder.", fix: "Check the path.", command: "ls /")

    func explain(_ report: FailureReport) -> AsyncThrowingStream<FailureExplanation, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(FailureExplanation(cause: explanation.cause, fix: ""))
            continuation.yield(explanation)
            continuation.finish()
        }
    }
}

/// Explaining a failed command from the Commands sidebar, with a real zsh and a fake model.
@Suite("Explain failure", .serialized, .timeLimit(.minutes(1)),
       .enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")))
@MainActor
struct ExplainFailureUITests {
    private func run(_ command: String, in pane: Pane) async -> Bool {
        let count = pane.timeline.entries.count
        pane.terminal.send(txt: command + "\r")
        return await waitUntil { pane.timeline.entries.count == count + 1 && pane.timeline.running == nil && pane.isAtCommandLine }
    }

    private func withSidebar(explainer: FakeExplainer?, open: Bool = true,
                             _ body: @MainActor (CommandTimelineSidebar, Pane, TestEnvironment) async throws -> Void) async throws {
        try await withWindow(explainer: explainer, openSidebar: open) { controller, pane, env in
            try await body(controller.timelineSidebar, pane, env)
        }
    }

    private func withWindow(explainer: FakeExplainer?, openSidebar: Bool,
                            _ body: @MainActor (TerminalWindowController, Pane, TestEnvironment) async throws -> Void) async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true, explainer: explainer)
        defer { env.tearDown() }
        // Otherwise the rest of an earlier command shows after what's inserted.
        env.preferences.suggestCommands = false
        let config = env.directory.appendingPathComponent("zdotdir")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "PS1='%# '\n".write(to: config.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        setenv("ZDOTDIR", config.path, 1)
        let controller = TerminalWindowController(directory: env.directory.path, environment: env.environment)
        unsetenv("ZDOTDIR")
        controller.window?.setContentSize(NSSize(width: 1100, height: 600))
        defer {
            controller.model.tabs.flatMap(\.panes).forEach { $0.shutDown() }
            controller.window?.close()
        }
        let pane = try #require(controller.model.selected?.focused)
        #expect(await waitUntil { pane.isAtCommandLine })
        #expect(await run("echo fine", in: pane))
        #expect(await run("ls /nonexistent-codec-path", in: pane))
        if openSidebar {
            controller.toggleCommandTimeline(nil)
            controller.window?.layoutIfNeeded()
        }
        try await body(controller, pane, env)
    }

    @Test func explainsAFailedCommandAndInsertsItsSuggestion() async throws {
        try await withSidebar(explainer: FakeExplainer()) { sidebar, pane, _ in
            let entries = sidebar.rows.compactMap(\.entry)
            let worked = try #require(entries.first { !$0.failed })
            let failed = try #require(entries.first { $0.failed })

            #expect(!sidebar.contextMenuItems(for: worked, row: 1).map(\.title).contains("Explain Failure"))
            let item = try #require(sidebar.contextMenuItems(for: failed, row: 2).first { $0.title == "Explain Failure" })
            #expect(item.isEnabled)

            sidebar.showOutput(of: worked, row: 1)
            #expect(sidebar.outputViewer?.explanation.isOffered == false)

            sidebar.showOutput(of: failed, row: 2, explain: true)
            let model = try #require(sidebar.outputViewer?.explanation)
            #expect(model.report?.command == "ls /nonexistent-codec-path")
            #expect(model.report?.output.contains("No such file or directory") == true)
            #expect(await waitUntil { model.state == .done(FakeExplainer().explanation) })

            // Its command goes on the command line, not run.
            sidebar.outputViewer?.actions.insertCommand("ls /")
            #expect(await waitUntil {
                let rows = pane.terminal.terminalContentSnapshot(region: .history(maximumScrollbackRows: 100))?.rows
                    .map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
                return rows.last == "% ls /"
            })
            #expect(pane.timeline.entries.count == 2)
        }
    }

    /// The status bar's Explain: the sidebar opens on the failed command and explains it.
    @Test func explainingTheLastFailureOpensTheSidebar() async throws {
        try await withWindow(explainer: FakeExplainer(), openSidebar: false) { controller, pane, _ in
            #expect(!controller.model.timelineVisible)
            controller.explainLastFailure(in: pane)
            #expect(controller.model.timelineVisible)
            let sidebar = controller.timelineSidebar!
            #expect(sidebar.selectedEntry?.command == "ls /nonexistent-codec-path")
            let model = try #require(sidebar.outputViewer?.explanation)
            #expect(await waitUntil { model.state == .done(FakeExplainer().explanation) })
        }
    }

    @Test func theTerminalsMenuExplainsTheLastFailure() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true, explainer: FakeExplainer())
        defer { env.tearDown() }
        let config = env.directory.appendingPathComponent("zdotdir")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "PS1='%# '\n".write(to: config.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        setenv("ZDOTDIR", config.path, 1)
        let host = FakeHost()
        let pane = env.makePane(host: host)
        unsetenv("ZDOTDIR")
        let window = makeTestWindow(size: NSSize(width: 800, height: 300))
        window.contentView = pane.view
        defer { pane.shutDown(); window.close() }
        #expect(await waitUntil { pane.isAtCommandLine })

        #expect(await run("echo fine", in: pane))
        #expect(!pane.contextMenu().items.map(\.title).contains("Explain Failure"))
        #expect(await run("ls /nonexistent-codec-path", in: pane))
        let menu = pane.contextMenu()
        #expect(menu.item(titled: "Explain Failure")?.isEnabled == true)
        menu.perform("Explain Failure")
        #expect(host.explained.map(\.command) == ["ls /nonexistent-codec-path"])

        env.preferences.explainFailures = false
        #expect(!pane.contextMenu().items.map(\.title).contains("Explain Failure"))
    }

    @Test func offersNothingWhenTurnedOffAndSaysWhyWhenUnavailable() async throws {
        try await withSidebar(explainer: FakeExplainer(availability: .unavailable("Turn it on."))) { sidebar, _, env in
            let failed = try #require(sidebar.rows.compactMap(\.entry).first { $0.failed })
            let item = try #require(sidebar.contextMenuItems(for: failed, row: 2).first { $0.title == "Explain Failure" })
            #expect(!item.isEnabled)
            sidebar.showOutput(of: failed, row: 2, explain: true)
            let model = try #require(sidebar.outputViewer?.explanation)
            #expect(model.isOffered)
            #expect(model.state == .idle)

            env.preferences.explainFailures = false
            #expect(!sidebar.contextMenuItems(for: failed, row: 2).map(\.title).contains("Explain Failure"))
            sidebar.showOutput(of: failed, row: 2)
            #expect(sidebar.outputViewer?.explanation.isOffered == false)
        }
    }
}
