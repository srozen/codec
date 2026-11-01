import Testing
import AppKit
import CodecCore
@testable import CodecUI

/// Reopening the windows, tabs and splits from last time.
@Suite("Reopening windows", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RestoreTests {
    private func folder(_ env: TestEnvironment, _ name: String) throws -> String {
        let url = env.directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func close(_ controllers: [TerminalWindowController]) {
        controllers.forEach { $0.window?.close() }
    }

    @Test func savesAndReopensTabsSplitsNamesAndFolders() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let (api, web, docs) = (try folder(env, "api"), try folder(env, "web"), try folder(env, "docs"))
        let original = TerminalWindowController(directory: api, environment: env.environment)
        defer { close([original]) }
        original.model.selected?.rename(to: "servers")
        original.splitRight(nil)
        original.model.selected?.focused.session.directory = web
        original.splitDown(nil)
        let first = try #require(original.model.selected?.panes.first)
        original.model.selected?.focus(first)
        original.newTab(nil)
        original.model.selected?.focused.session.directory = docs
        original.select(original.model.tabs[0])

        let saved = original.savedState
        #expect(saved.selectedTab == 0)
        #expect(saved.tabs.map(\.title) == ["servers", nil])
        #expect(saved.tabs[0].layout == .split(.horizontal, [.pane(directory: api), .split(.vertical, [.pane(directory: web), .pane(directory: web)])]))
        #expect(saved.tabs[0].focusedPane == 0)
        #expect(saved.tabs[1].layout == .pane(directory: docs))

        // A folder that's gone opens the nearest one left.
        try FileManager.default.removeItem(atPath: docs)
        let reopened = TerminalWindowController(directory: nil, environment: env.environment, restoring: saved)
        defer { close([reopened]) }
        #expect(reopened.model.tabs.count == 2)
        #expect(reopened.model.selected === reopened.model.tabs[0])
        #expect(reopened.model.tabs[0].title == "servers")
        #expect(reopened.model.tabs[0].panes.map(\.session.directory) == [api, web, web])
        #expect(reopened.model.tabs[0].focused === reopened.model.tabs[0].panes[0])
        #expect(reopened.model.tabs[1].panes.map(\.session.directory) == [env.directory.path])
        #expect(reopened.savedState.tabs[0] == saved.tabs[0])
        #expect(reopened.paneContainer.subviews.first is PaneSplitView)
    }

    @Test func nothingToReopenOpensAPlainWindow() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let empty = SavedWindow(frame: nil, tabs: [SavedTab(title: nil, layout: .split(.horizontal, []), focusedPane: 0)], selectedTab: 3)
        let controller = TerminalWindowController(directory: env.directory.path, environment: env.environment, restoring: empty)
        defer { close([controller]) }
        #expect(controller.model.tabs.count == 1)
        #expect(controller.model.selected?.focused.session.directory == env.directory.path)
    }

    @Test func savesAMomentAfterAChange() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let app = AppDelegate(environment: env.environment)
        defer { close(app.windows) }
        app.newWindow(nil)
        let window = try #require(app.windows.first)
        window.newTab(nil)
        window.model.selected?.rename(to: "logs")
        #expect(await waitUntil(timeout: .seconds(5)) {
            SavedWorkspace.load(from: env.preferences.stateDefaults)?.windows.first?.tabs.map(\.title) == [nil, "logs"]
        })
    }

    @Test func theAppSavesOnQuitAndReopensAtLaunch() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let project = try folder(env, "project")
        let defaults = env.preferences.stateDefaults
        SavedWorkspace(windows: [
            SavedWindow(frame: nil, tabs: [SavedTab(title: "front", layout: .pane(directory: project), focusedPane: 0)], selectedTab: 0),
            SavedWindow(frame: nil, tabs: [SavedTab(title: "back", layout: .pane(directory: project), focusedPane: 0),
                                           SavedTab(title: nil, layout: .pane(directory: project), focusedPane: 0)], selectedTab: 1),
        ]).save(to: defaults)

        let app = AppDelegate(environment: env.environment)
        defer { close(app.windows) }
        #expect(app.restoreWindows())
        #expect(app.windows.count == 2)
        #expect(Set(app.windows.map { $0.model.tabs.count }) == [1, 2])

        // Closing a window forgets it; quitting keeps what's open.
        let back = try #require(app.windows.first { $0.model.tabs.count == 2 })
        back.window?.close()
        #expect(app.windows.count == 1)
        app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        let saved = try #require(SavedWorkspace.load(from: defaults))
        #expect(saved.windows.map { $0.tabs.map(\.title) } == [["front"]])

        // With the setting off, launch opens a plain window instead.
        env.preferences.restoreWindows = false
        let fresh = AppDelegate(environment: env.environment)
        #expect(!fresh.restoreWindows())
        #expect(fresh.windows.isEmpty)
    }
}
