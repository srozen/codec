import Testing
import Foundation
@testable import CodecCore

@Suite("CommandTimeline")
struct CommandTimelineTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func recordsACommandFromStartToFinish() {
        var timeline = CommandTimeline()
        let id = timeline.begin(command: "make", directory: "/code", started: start, block: .init(prompt: 3, output: 4))
        #expect(timeline.running?.id == id)
        #expect(timeline.entries.first?.status == .running)

        timeline.updateRunningCommand("make\n  test")
        timeline.finish(exitCode: 2, duration: 1.5, output: CapturedOutput(lines: ["building", "error: nope", ""]))
        let entry = try! #require(timeline.entries.first)
        #expect(timeline.running == nil)
        #expect(entry.command == "make\n  test")
        #expect(entry.screenCommand == "make")
        #expect(entry.status == .failed(2))
        #expect(entry.failed)
        #expect(entry.duration == 1.5)
        #expect(entry.output?.summary == "error: nope")
        #expect(entry.output?.lineCount == 2)
    }

    /// A shell that was killed never reports; the next command doesn't leave the old one running.
    @Test func abandonsACommandThatNeverFinished() {
        var timeline = CommandTimeline()
        timeline.begin(command: "sleep 99", directory: "/", started: start, block: nil)
        timeline.begin(command: "ls", directory: "/", started: start, block: nil)
        #expect(timeline.entries.map(\.isRunning) == [false, true])
        #expect(timeline.entries[0].exitCode == -1)
    }

    @Test func filtersByCommandOutputAndFailure() {
        var timeline = CommandTimeline()
        timeline.begin(command: "git status", directory: "/", started: start, block: nil)
        timeline.finish(exitCode: 0, duration: 0, output: CapturedOutput(lines: ["On branch main"]))
        timeline.begin(command: "swift build", directory: "/", started: start, block: nil)
        timeline.finish(exitCode: 1, duration: 3, output: CapturedOutput(lines: ["Compiling", "error: Cannot find 'x' in scope"]))
        timeline.begin(command: "ls", directory: "/", started: start, block: nil)
        timeline.finish(exitCode: 0, duration: 0, output: nil)

        #expect(timeline.entries(matching: "").count == 3)
        #expect(timeline.entries(matching: "GIT").map(\.command) == ["git status"])
        #expect(timeline.entries(matching: "cannot find").map(\.command) == ["swift build"])
        #expect(timeline.entries(matching: "", failedOnly: true).map(\.command) == ["swift build"])
        #expect(timeline.entries(matching: "branch", failedOnly: true).isEmpty)
    }

    /// The sidebar's filter matches as Find does: Aa, ab and .* apply, and a pattern that isn't valid
    /// matches nothing.
    @Test func filtersWithFindsOptions() {
        var timeline = CommandTimeline()
        timeline.begin(command: "npm test", directory: "/", started: start, block: nil)
        timeline.finish(exitCode: 1, duration: 2, output: CapturedOutput(lines: ["Error: connect ECONNREFUSED 127.0.0.1:5432"]))
        timeline.begin(command: "curl localhost:4000", directory: "/", started: start, block: nil)
        timeline.finish(exitCode: 7, duration: 0, output: CapturedOutput(lines: ["curl: (7) Connection refused"]))
        timeline.begin(command: "echo refusedly", directory: "/", started: start, block: nil)
        timeline.finish(exitCode: 0, duration: 0, output: CapturedOutput(lines: ["refusedly"]))

        func commands(_ query: String, _ options: FindOptions = FindOptions(), failedOnly: Bool = false) -> [String] {
            timeline.entries(matching: TimelineFilter(query: query, options: options, failedOnly: failedOnly)).map(\.command)
        }
        #expect(commands("refused") == ["npm test", "curl localhost:4000", "echo refusedly"])
        #expect(commands("refused", failedOnly: true) == ["npm test", "curl localhost:4000"])
        #expect(commands("Refused", FindOptions(caseSensitive: true)).isEmpty)
        #expect(commands("refused", FindOptions(wholeWord: true)) == ["curl localhost:4000"])
        #expect(commands("econn|:4000", FindOptions(regex: true)) == ["npm test", "curl localhost:4000"])
        #expect(commands("econn|:4000").isEmpty)
        #expect(commands("  ").count == 3)

        let invalid = TimelineFilter(query: "(", options: FindOptions(regex: true))
        #expect(invalid.isInvalid)
        #expect(timeline.entries(matching: invalid).isEmpty)
        #expect(!TimelineFilter(query: "(").isInvalid)
        #expect(!TimelineFilter(query: "", options: FindOptions(regex: true)).isInvalid)
    }

    @Test func findsTheMatchWithTheLinesAroundIt() throws {
        let output = CapturedOutput(lines: [
            "> api@1.0.0 test", "", "    at TCPConnectWrap.afterConnect [as oncomplete] (node:net:1555:16) ECONNREFUSED here",
            "  done", "",
        ])
        let expression = try #require(TextSearch.expression(for: "econnrefused", options: FindOptions()))
        let match = try #require(output.firstMatch(of: expression))
        #expect(match.index == 2)
        #expect(match.line == "at TCPConnectWrap.afterConnect [as oncomplete] (node:net:1555:16) ECONNREFUSED here")
        #expect(Array(match.line)[match.range].map(String.init).joined() == "ECONNREFUSED")
        #expect(match.before == "> api@1.0.0 test")
        #expect(match.after == "done")
        // A long line starts a little before the match, so a narrow list still shows it.
        #expect(match.excerpt(leading: 6) == "…5:16) ECONNREFUSED here")
        #expect(match.excerpt(leading: 100) == match.line)

        func firstMatch(_ query: String) -> OutputMatch? {
            TextSearch.expression(for: query, options: FindOptions()).flatMap(output.firstMatch)
        }
        let first = try #require(firstMatch("api"))
        #expect(first.index == 0 && first.before == nil && first.range == 2..<5)
        #expect(firstMatch("nowhere") == nil)
    }

    @Test func forgetsWhereCommandsWereOnScreen() {
        var timeline = CommandTimeline()
        let first = timeline.begin(command: "a", directory: "/", started: start, block: .init(prompt: 0, output: 1))
        timeline.begin(command: "b", directory: "/", started: start, block: .init(prompt: 2, output: 3))
        timeline.forgetBlock(of: first)
        #expect(timeline.entries.map { $0.block != nil } == [false, true])
        timeline.forgetBlocks()
        #expect(timeline.entries.allSatisfy { $0.block == nil })
    }

    @Test func dropsTheOldestEntriesPastTheLimit() {
        var timeline = CommandTimeline(limit: 3)
        for index in 0..<5 {
            timeline.begin(command: "echo \(index)", directory: "/", started: start, block: nil)
            timeline.finish(exitCode: 0, duration: 0, output: nil)
        }
        #expect(timeline.entries.map(\.command) == ["echo 2", "echo 3", "echo 4"])
        #expect(timeline.entry(id: 5)?.command == "echo 4")
    }

    /// Past the budget, older commands lose their output (but stay listed) so newer ones keep theirs.
    @Test func keepsOutputWithinItsBudget() {
        var timeline = CommandTimeline(outputBudget: 25)
        for index in 0..<3 {
            timeline.begin(command: "cmd \(index)", directory: "/", started: start, block: nil)
            timeline.finish(exitCode: 0, duration: 0, output: CapturedOutput(lines: ["0123456789"]))
        }
        #expect(timeline.entries.map { $0.output != nil } == [false, true, true])
    }

    @Test func keepsTheStartAndEndOfLongOutput() {
        let lines = (1...20).map { "line \($0)" }
        let output = CapturedOutput(lines: lines, head: 2, tail: 3)
        #expect(output.lineCount == 20)
        #expect(output.omitted == 15)
        #expect(output.text == "line 1\nline 2\n… 15 lines …\nline 18\nline 19\nline 20")
        #expect(output.summary == "line 20")
    }

    @Test func findsTheFirstMatchingLine() {
        let output = CapturedOutput(lines: ["ok", "  Warning: low disk", "warning again", "", "  "])
        #expect(output.firstLine(matching: "warning")?.line == "Warning: low disk")
        #expect(output.firstLine(matching: "warning")?.index == 1)
        #expect(output.firstLine(matching: "nothing") == nil)
        #expect(output.firstLine(matching: "") == nil)
        #expect(output.summary == "warning again")
        #expect(CapturedOutput(lines: ["", " "]).isEmpty)
        #expect(CapturedOutput(lines: []).summary == nil)
    }
}
