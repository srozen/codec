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

        let rebuilt = try #require(saved.build { directory, _ in Leaf(directory) })
        #expect(rebuilt.leaves.map(\.name) == ["/a", "/b", "/c"])
        #expect(rebuilt.saved { $0.name } == saved)
    }

    @Test func collapsesSplitsLeftWithOneChild() {
        let damaged = SavedLayout.split(.horizontal, [.split(.vertical, [.pane(directory: "/a")])])
        let rebuilt = damaged.build { directory, _ in Leaf(directory) }
        #expect(rebuilt.map { $0.saved { $0.name } } == .pane(directory: "/a"))
        #expect(SavedLayout.split(.vertical, []).build { directory, _ in Leaf(directory) } == nil)
    }

    @Test func keepsSizesAndContentsNames() throws {
        let a = Leaf("/a"), b = Leaf("/b"), c = Leaf("/c")
        let layout = SplitLayout.leaf(a).splitting(a, with: b, axis: .horizontal).splitting(b, with: c, axis: .vertical)
        let saved = layout.saved(directory: \.name, contents: { $0 === c ? "c-pane" : nil },
                                 sizes: { $0.axis == .horizontal ? [0.7, 0.3] : [0.4, 0.6] })
        #expect(saved == .split(.horizontal, [
            .pane(directory: "/a"),
            .split(.vertical, [.pane(directory: "/b"), .pane(directory: "/c", contents: "c-pane")], sizes: [0.4, 0.6]),
        ], sizes: [0.7, 0.3]))
        var names: [String?] = []
        var sizes: [[Double]] = []
        let rebuilt = try #require(saved.build({ directory, name in
            names.append(name)
            return Leaf(directory)
        }, sizes: { _, shares in sizes.append(shares) }))
        #expect(rebuilt.leaves.count == 3)
        #expect(names == [nil, nil, "c-pane"])
        #expect(sizes == [[0.4, 0.6], [0.7, 0.3]])
        // Sizes that don't fit what was built are left out.
        var dropped: [[Double]] = []
        _ = SavedLayout.split(.horizontal, [.pane(directory: "/a"), .split(.vertical, []), .pane(directory: "/b")], sizes: [0.2, 0.3, 0.5])
            .build({ directory, _ in Leaf(directory) }, sizes: { _, shares in dropped.append(shares) })
        #expect(dropped.isEmpty)
    }

    @Test func readsWhatEarlierVersionsSaved() throws {
        let json = #"{"windows":[{"tabs":[{"layout":{"split":{"_0":"horizontal","_1":[{"pane":{"directory":"\/a"}},{"pane":{"directory":"\/b"}}]}},"focusedPane":1}],"selectedTab":0}]}"#
        let workspace = try JSONDecoder().decode(SavedWorkspace.self, from: Data(json.utf8))
        #expect(workspace.windows.first?.tabs.first?.layout == .split(.horizontal, [.pane(directory: "/a"), .pane(directory: "/b")]))
    }

    @Test func carriesSplitSharesOver() {
        // Unchanged.
        #expect(SplitShares.carry([0.7, 0.3], from: ["a", "b"], to: ["a", "b"]) == [0.7, 0.3])
        // A pane split in two: the new one takes half of the one it came from.
        #expect(SplitShares.carry([0.6, 0.4], from: ["a", "b"], to: ["a", "c", "b"]) == [0.3, 0.3, 0.4])
        // A pane closed: the others share its space.
        let closed = SplitShares.carry([0.5, 0.25, 0.25], from: ["a", "b", "c"], to: ["a", "c"])
        #expect(abs(closed[0] - 2 / 3) < 1e-9 && abs(closed[1] - 1 / 3) < 1e-9)
        // A new first one, and nothing known.
        #expect(SplitShares.carry([0.8, 0.2], from: ["a", "b"], to: ["z", "a", "b"]) == [0.4, 0.4, 0.2])
        #expect(SplitShares.carry([1], from: ["x"], to: ["y", "z"]) == [0.5, 0.5])
        #expect(SplitShares.normalized([0, 1]) == [0.5, 0.5])
    }

    @Test func keepsATimelineWithItsTranscript() throws {
        var timeline = CommandTimeline()
        timeline.begin(command: "old", directory: "/", started: Date(timeIntervalSince1970: 0), block: .init(prompt: 2, output: 3))
        timeline.finish(exitCode: 0, duration: 1, output: CapturedOutput(lines: ["gone"]))
        timeline.begin(command: "make", directory: "/", started: Date(timeIntervalSince1970: 10), block: .init(prompt: 50, output: 51, commandLine: "% make"))
        timeline.finish(exitCode: 2, duration: 3, output: CapturedOutput(lines: ["error"]))
        timeline.begin(command: "npm run dev", directory: "/", started: Date(timeIntervalSince1970: 20), block: .init(prompt: 60, output: 61))

        let rebased = timeline.rebased(firstRow: 40)
        #expect(rebased.entries.map(\.block) == [nil, .init(prompt: 10, output: 11, commandLine: "% make"), .init(prompt: 20, output: 21)])
        // What was running didn't report back.
        #expect(rebased.entries.last?.exitCode == -1)
        #expect(rebased.entries[1].output?.text == "error")

        let contents = SavedPaneContents(transcript: "\u{1B}[31mred\u{1B}[0m\r\n", timeline: rebased, listStart: 2,
                                         saved: Date(timeIntervalSince1970: 100))
        let decoded = try JSONDecoder().decode(SavedPaneContents.self, from: JSONEncoder().encode(contents))
        #expect(decoded == contents)
        // New commands carry on from the restored ids.
        var carried = decoded.timeline
        #expect(carried.begin(command: "ls", directory: "/", started: Date(), block: nil) == 4)
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
