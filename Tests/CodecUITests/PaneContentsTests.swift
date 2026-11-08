import Testing
import AppKit
import SwiftTerm
import CodecCore
@testable import CodecUI

/// Split sizes, what panes showed and closed tabs, kept and brought back.
@Suite("Keeping panes", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct PaneContentsTests {
    private func makeWindow(_ env: TestEnvironment) -> TerminalWindowController {
        let controller = TerminalWindowController(directory: env.directory.path, environment: env.environment)
        controller.window?.setContentSize(NSSize(width: 1000, height: 600))
        controller.window?.layoutIfNeeded()
        return controller
    }

    private func rootSplit(_ controller: TerminalWindowController) throws -> PaneSplitView {
        controller.window?.layoutIfNeeded()
        return try #require(controller.paneContainer.subviews.first as? PaneSplitView)
    }

    private func widths(_ split: PaneSplitView) -> [CGFloat] {
        split.arrangedSubviews.map(\.frame.width)
    }

    // MARK: Split sizes

    @Test func splitsKeepTheirSizesAcrossTabsAndSaving() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let controller = makeWindow(env)
        defer { controller.window?.close() }
        let tab = try #require(controller.model.selected)
        controller.splitRight(nil)
        var split = try rootSplit(controller)
        split.setPosition(300, ofDividerAt: 0)
        controller.window?.layoutIfNeeded()
        let dragged = widths(split)
        #expect(abs(dragged[0] - 300) < 2)
        let key = try #require(TerminalTab.SplitKey(tab.layout))
        #expect(abs((tab.shares[key]?[0] ?? 0) - 0.3) < 0.01)

        // Away and back.
        controller.newTab(nil)
        controller.select(tab)
        split = try rootSplit(controller)
        #expect(zip(widths(split), dragged).allSatisfy { abs($0 - $1) < 2 })

        // Splitting the narrow pane again halves it, and leaves the other alone.
        tab.focus(tab.panes[0])
        controller.splitRight(nil)
        split = try rootSplit(controller)
        let thirds = widths(split)
        #expect(thirds.count == 3 && abs(thirds[0] - thirds[1]) < 3 && abs(thirds[2] - dragged[1]) < 3)

        // Saved, and reopened at the same sizes.
        let saved = controller.savedState
        guard case .split(_, _, let sizes?) = saved.tabs[0].layout else { Issue.record("No sizes saved"); return }
        #expect(abs(sizes[2] - 0.7) < 0.01)
        let reopened = TerminalWindowController(directory: nil, environment: env.environment, restoring: saved)
        defer { reopened.window?.close() }
        reopened.window?.setContentSize(NSSize(width: 1000, height: 600))
        let restored = widths(try rootSplit(reopened))
        #expect(zip(restored, thirds).allSatisfy { abs($0 - $1) < 3 })
    }

    @Test func splittingLeftOrUpKeepsTheSizes() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let controller = makeWindow(env)
        defer { controller.window?.close() }
        let tab = try #require(controller.model.selected)
        controller.splitRight(nil)
        var split = try rootSplit(controller)
        split.setPosition(300, ofDividerAt: 0)
        controller.window?.layoutIfNeeded()
        let dragged = widths(split)

        // Left of the wide pane: it gives the new one half of its width, the narrow one keeps its own.
        let wide = tab.panes[1]
        controller.splitLeft(nil)
        split = try rootSplit(controller)
        let thirds = widths(split)
        #expect(tab.panes[1] === tab.focused && tab.panes[2] === wide)
        #expect(thirds.count == 3 && abs(thirds[0] - dragged[0]) < 3 && abs(thirds[1] - thirds[2]) < 3)

        // Above the narrow pane: the columns stay as they were.
        tab.focus(tab.panes[0])
        controller.splitUp(nil)
        split = try rootSplit(controller)
        #expect(zip(widths(split), thirds).allSatisfy { abs($0 - $1) < 3 })
        #expect(tab.panes[0] === tab.focused)
    }

    // MARK: What panes showed

    @Test func keepsTheScrollbackInColorAndShowsItAgain() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let window = makeTestWindow(size: NSSize(width: 700, height: 300))
        defer { window.close() }
        let pane = env.makePane()
        window.contentView = pane.view
        pane.view.layoutSubtreeIfNeeded()
        defer { pane.shutDown() }
        try await Task.sleep(for: .milliseconds(300))
        pane.terminal.feed(text: "\r\nplain \u{1B}[1;31mbold red\u{1B}[0m and \u{1B}[48;5;200mpink\u{1B}[0m\r\n")
        #expect(await waitUntil { pane.terminal.visibleRowsText(0..<10).joined().contains("bold red") })

        let contents = try #require(pane.savedContents(at: Date(timeIntervalSince1970: 0)))
        #expect(contents.transcript.contains("plain \u{1B}[0;1;31mbold red\u{1B}[0m and \u{1B}[0;48;5;200mpink"))
        #expect(!contents.transcript.contains("\u{1B}[0m\u{1B}[0m"))
        #expect(!contents.transcript.contains("\0") && !contents.transcript.contains("pink\u{1B}[0m "))

        // A new pane shows it, the same cells, with a line saying it's from before.
        let restored = Pane(directory: env.directory.path, environment: env.environment, restoring: contents)
        defer { restored.shutDown() }
        let other = makeTestWindow(size: NSSize(width: 700, height: 300))
        defer { other.close() }
        other.contentView = restored.view
        restored.view.layoutSubtreeIfNeeded()
        #expect(await waitUntil { restored.terminal.visibleRowsText(0..<10).joined().contains("── Restored ·") })
        func cells(_ pane: Pane) -> [TerminalCellSnapshot]? {
            pane.terminal.terminalContentSnapshot(region: .history(maximumScrollbackRows: 100))?.rows
                .first { $0.text.contains("bold red") }?.cells
                .filter { !$0.text.unicodeScalars.allSatisfy { $0 == " " || $0 == "\0" } }
        }
        #expect(cells(restored) != nil && cells(restored) == cells(pane))
    }

    @Test func bringsBackTheCommandsAndFindsThemOnScreen() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let config = env.directory.appendingPathComponent("zdotdir")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "PS1='%# '\n".write(to: config.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        setenv("ZDOTDIR", config.path, 1)
        defer { unsetenv("ZDOTDIR") }
        func show(_ pane: Pane) -> NSWindow {
            let window = makeTestWindow(size: NSSize(width: 800, height: 300))
            window.contentView = pane.view
            pane.view.layoutSubtreeIfNeeded()
            return window
        }
        func run(_ command: String, in pane: Pane) async -> Bool {
            let count = pane.timeline.entries.count
            try? await Task.sleep(for: .milliseconds(200))
            pane.terminal.send(txt: command + "\r")
            return await waitUntil { pane.timeline.entries.count == count + 1 && pane.timeline.running == nil && pane.isAtCommandLine }
        }

        let pane = env.makePane(host: FakeHost())
        let window = show(pane)
        defer { window.close() }
        #expect(await waitUntil { pane.isAtCommandLine })
        #expect(await run("echo first-run", in: pane))
        #expect(await run("seq 1 5", in: pane))
        // Its output is kept once the prompt after it is drawn, which can come a moment after the
        // pane is back at the command line.
        #expect(await waitUntil { pane.timeline.entries.last?.output != nil })
        let contents = try #require(pane.savedContents())
        pane.shutDown()
        #expect(contents.timeline.entries.map(\.command) == ["echo first-run", "seq 1 5"])
        #expect(contents.timeline.entries.allSatisfy { $0.block != nil })
        // Saved up to the prompt it was at, not including it.
        #expect(!contents.transcript.hasSuffix("% \r\n"))

        let restored = Pane(directory: env.directory.path, environment: env.environment, restoring: contents)
        let host = FakeHost()
        restored.host = host
        let other = show(restored)
        defer {
            restored.shutDown()
            other.close()
        }
        #expect(await waitUntil { restored.isAtCommandLine })
        #expect(restored.timeline.entries.map(\.command) == ["echo first-run", "seq 1 5"])
        #expect(restored.timeline.entries[1].output?.text == "1\n2\n3\n4\n5")
        // The old commands are found on screen, above the new ones.
        #expect(await run("echo after", in: restored))
        let first = try #require(restored.timeline.entries.first)
        let rows = try #require(restored.rows(of: first))
        let text = restored.lines(of: rows).lines.joined(separator: "\n")
        #expect(text.contains("echo first-run") && text.contains("first-run"))
        #expect(restored.timeline.entries.last?.id == 3)
    }

    // MARK: Reopening closed tabs

    @Test func reopensTheTabClosedLast() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let controller = makeWindow(env)
        defer { controller.window?.close() }
        let sub = env.directory.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let first = try #require(controller.model.selected)
        controller.newTab(nil)
        let tab = try #require(controller.model.selected)
        tab.rename(to: "logs")
        tab.focused.session.directory = sub.path
        controller.splitDown(nil)
        try await Task.sleep(for: .milliseconds(300))
        tab.panes[0].terminal.feed(text: "\r\nkept-for-later\r\n")
        #expect(await waitUntil { tab.panes[0].terminal.visibleRowsText(0..<10).joined().contains("kept-for-later") })

        let reopen = NSMenuItem(title: "", action: #selector(TerminalWindowController.reopenClosedTab(_:)), keyEquivalent: "")
        #expect(!controller.validateMenuItem(reopen))
        controller.requestClose(tab: tab)
        #expect(controller.model.tabs.count == 1)
        #expect(controller.validateMenuItem(reopen))

        controller.select(first)
        controller.reopenClosedTab(nil)
        #expect(controller.model.tabs.count == 2)
        let back = try #require(controller.model.selected)
        #expect(back !== tab && back.title == "logs")
        #expect(back.panes.map(\.session.directory) == [sub.path, sub.path])
        #expect(await waitUntil { back.panes[0].terminal.visibleRowsText(0..<10).joined().contains("kept-for-later") })
        #expect(!controller.validateMenuItem(reopen))
    }

    @Test func aClosedWindowsTabsCanComeBackToo() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let app = AppDelegate(environment: env.environment)
        defer { app.windows.forEach { $0.window?.close() } }
        app.newWindow(nil)
        let window = try #require(app.windows.first)
        window.model.selected?.rename(to: "one")
        window.newTab(nil)
        window.model.selected?.rename(to: "two")
        window.window?.close()
        #expect(app.windows.isEmpty)
        // No window: ⇧⌘T opens one for it, the tab that was in front first.
        app.reopenClosedTab(nil)
        #expect(app.windows.first?.model.tabs.map(\.title) == ["two"])
        app.reopenClosedTab(nil)
        #expect(app.windows.first?.model.tabs.map(\.title) == ["two", "one"])
    }

    // MARK: Across launches

    @Test func keepsWhatPanesShowedWhenQuitting() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let app = AppDelegate(environment: env.environment)
        app.newWindow(nil)
        let pane = try #require(app.windows.first?.model.selected?.focused)
        try await Task.sleep(for: .milliseconds(300))
        pane.terminal.feed(text: "\r\nyesterday's build output\r\n")
        #expect(await waitUntil { pane.terminal.visibleRowsText(0..<10).joined().contains("yesterday's build output") })
        app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        app.windows.forEach { $0.window?.close() }

        let folder = env.directory.appendingPathComponent("saved-panes")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files == [pane.session.id.uuidString + ".json"])
        let permissions = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(files[0]).path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)

        let relaunched = AppDelegate(environment: env.environment)
        defer { relaunched.windows.forEach { $0.window?.close() } }
        #expect(relaunched.restoreWindows())
        let restored = try #require(relaunched.windows.first?.model.selected?.focused)
        relaunched.windows.first?.window?.layoutIfNeeded()
        #expect(await waitUntil { restored.terminal.visibleRowsText(0..<20).joined().contains("yesterday's build output") })
        // Read once, then gone from disk.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)

        // With the setting off, nothing is written.
        env.preferences.restorePaneContents = false
        relaunched.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
}
