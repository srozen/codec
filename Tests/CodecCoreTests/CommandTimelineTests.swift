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
