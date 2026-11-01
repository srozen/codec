import Testing
import Foundation
@testable import CodecCore

@Suite("Saved workspace")
struct SavedWorkspaceTests {
    @Test func savesALayoutAndBuildsItAgain() throws {
        let a = Leaf("/a"), b = Leaf("/b"), c = Leaf("/c")
        let layout = SplitLayout.leaf(a).splitting(a, with: b, axis: .horizontal).splitting(b, with: c, axis: .vertical)
        let saved = layout.saved { $0.name }
        #expect(saved == .split(.horizontal, [.pane(directory: "/a"), .split(.vertical, [.pane(directory: "/b"), .pane(directory: "/c")])]))
        #expect(saved.paneCount == 3)

        let rebuilt = try #require(saved.build { Leaf($0) })
        #expect(rebuilt.leaves.map(\.name) == ["/a", "/b", "/c"])
        #expect(rebuilt.saved { $0.name } == saved)
    }

    @Test func collapsesSplitsLeftWithOneChild() {
        let damaged = SavedLayout.split(.horizontal, [.split(.vertical, [.pane(directory: "/a")])])
        let rebuilt = damaged.build { Leaf($0) }
        #expect(rebuilt.map { $0.saved { $0.name } } == .pane(directory: "/a"))
        #expect(SavedLayout.split(.vertical, []).build { Leaf($0) } == nil)
    }

    @Test func roundTripsThroughDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "saved-workspace-\(UUID())"))
        #expect(SavedWorkspace.load(from: defaults) == nil)
        let workspace = SavedWorkspace(windows: [
            SavedWindow(frame: CGRect(x: 10, y: 20, width: 800, height: 500), tabs: [
                SavedTab(title: "server", layout: .split(.horizontal, [.pane(directory: "/a"), .pane(directory: "/b")]), focusedPane: 1),
                SavedTab(title: nil, layout: .pane(directory: "/c"), focusedPane: 0),
            ], selectedTab: 1),
            SavedWindow(frame: nil, tabs: [SavedTab(title: nil, layout: .pane(directory: "/"), focusedPane: 0)], selectedTab: 0),
        ])
        workspace.save(to: defaults)
        #expect(SavedWorkspace.load(from: defaults) == workspace)
        // Something unreadable is as good as nothing.
        defaults.set(Data("nope".utf8), forKey: SavedWorkspace.defaultsKey)
        #expect(SavedWorkspace.load(from: defaults) == nil)
    }

    @Test func fallsBackToTheNearestFolderLeft() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("saved-\(UUID())").resolvingSymlinksInPath()
        let kept = root.appendingPathComponent("kept")
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(SavedWorkspace.existingDirectory(kept.path, home: "/home") == kept.path)
        #expect(SavedWorkspace.existingDirectory(kept.appendingPathComponent("gone/deeper").path, home: "/home") == kept.path)
        #expect(SavedWorkspace.existingDirectory("/", home: "/home") == "/")
        #expect(SavedWorkspace.existingDirectory("relative/nowhere", home: "/home") == "/home")
    }
}
