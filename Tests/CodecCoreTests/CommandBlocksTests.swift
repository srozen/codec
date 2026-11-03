import Foundation
import Testing
@testable import CodecCore

@Suite("CommandBlocks")
struct CommandBlocksTests {
    private func rows(_ lines: [String], from first: Int = 0, wrapped: Set<Int> = []) -> [ScreenRow] {
        lines.enumerated().map { ScreenRow(row: first + $0.offset, text: $0.element, isWrapped: wrapped.contains(first + $0.offset)) }
    }

    @Test func locatesTheCommandLineAndItsPrompt() {
        let screen = rows(["", "~/code ⎇ main", "", "❯ make test   ", "building…", "done"], from: 40)
        let block = CommandBlocks.locate(command: "make test", in: screen, cursorRow: 45, promptLines: 4)
        #expect(block == .init(prompt: 40, output: 44, commandLine: "❯ make test"))
    }

    /// Output may already be on screen when Codec looks; the command line is found above it.
    @Test func ignoresOutputBelowTheCommandLine() {
        let screen = rows(["% echo hi", "hi", "% "], from: 7)
        #expect(CommandBlocks.locate(command: "echo hi", in: screen, cursorRow: 9, promptLines: 1)
                == .init(prompt: 7, output: 8, commandLine: "% echo hi"))
    }

    @Test func joinsSoftWrappedCommandLines() {
        let screen = rows(["% echo aaaa", "aaaa bbb", "out"], from: 0, wrapped: [1])
        #expect(CommandBlocks.locate(command: "echo aaaaaaaa bbb", in: screen, cursorRow: 2, promptLines: 1)
                == .init(prompt: 0, output: 2, commandLine: "% echo aaaaaaaa bbb"))
    }

    @Test func returnsNothingWhenTheCommandIsntOnScreen() {
        let screen = rows(["% ls", "a b"])
        #expect(CommandBlocks.locate(command: "git status", in: screen, cursorRow: 1, promptLines: 1) == nil)
        #expect(CommandBlocks.locate(command: "  ", in: screen, cursorRow: 1, promptLines: 1) == nil)
    }

    /// After the terminal rewraps its lines, each command is found again, above the one after it.
    @Test func relocatesCommandsAfterARewrap() {
        let screen = rows(["% echo a", "a", "% ls -la /some/long/pa", "th", "x", "% echo a", "a", "% "], from: 30,
                          wrapped: [33])
        let found = CommandBlocks.relocate(commands: [("echo a", "% echo a"), ("ls -la /some/long/path", nil),
                                                      ("echo a", "% echo a"), ("gone", "% gone")],
                                           in: screen, lastRow: 36, promptLines: 1)
        #expect(found == [.init(prompt: 30, output: 31, commandLine: "% echo a"),
                          .init(prompt: 32, output: 34, commandLine: "% ls -la /some/long/path"),
                          .init(prompt: 35, output: 36, commandLine: "% echo a"), nil])
    }

    /// Output can end with its own command, as `ls` printing `Tools` does. Found again, the command goes
    /// on its command line, not on that line of output.
    @Test(arguments: [
        (["❯ ls", "Desktop  Pictures  Tools", "❯ "], 1),
        (["~/code ⎇ main", "", "❯ ls", "Desktop  Pictures  Tools", "~/code ⎇ main", "", "❯ "], 3),
    ])
    func relocatesACommandAboveOutputThatEndsWithIt(lines: [String], promptLines: Int) throws {
        let screen = rows(lines, from: 20)
        let commandLine = try #require(screen.first { $0.text == "❯ ls" }).row
        // As the screen was when the command started, before its output.
        let started = rows(Array(lines.prefix(commandLine - 19)) + [""], from: 20)
        let first = try #require(CommandBlocks.locate(command: "ls", in: started, cursorRow: commandLine + 1,
                                                      promptLines: promptLines))
        #expect(first == .init(prompt: 20, output: commandLine + 1, commandLine: "❯ ls"))
        let found = CommandBlocks.relocate(commands: [("ls", first.commandLine)], in: screen,
                                           lastRow: 20 + lines.count - promptLines - 1, promptLines: promptLines)
        #expect(found == [first])
    }

    /// The same, for output that ends with the whole command: `cat list` printing `wildcat list`, here
    /// after a rewrap broke both lines differently than before.
    @Test(arguments: [1, 3])
    func relocatesACommandAboveOutputThatEndsWithAllOfIt(promptLines: Int) {
        let prompt = promptLines == 1 ? [] : ["~/code ⎇ main", ""]
        let before = rows(prompt + ["❯ cat list", "first.txt", "wildcat list"] + prompt + ["❯ "], from: 0)
        let first = CommandBlocks.locate(command: "cat list", in: before, cursorRow: promptLines, promptLines: promptLines)
        #expect(first?.prompt == 0)
        // Narrower now, the long lines take two rows.
        let after = rows(prompt + ["❯ cat l", "ist", "first.txt", "wildc", "at list"] + prompt + ["❯ "], from: 0,
                         wrapped: [promptLines, promptLines + 3])
        let found = CommandBlocks.relocate(commands: [("cat list", first?.commandLine)], in: after,
                                           lastRow: promptLines + 3, promptLines: promptLines)
        #expect(found == [.init(prompt: 0, output: promptLines + 1, commandLine: "❯ cat list")])
        // Without the command line, the output's line would have won.
        #expect(CommandBlocks.relocate(commands: [("cat list", nil)], in: after, lastRow: promptLines + 3,
                                       promptLines: promptLines).first??.output == promptLines + 4)
    }

    /// Spaces may come and go where a rewrap breaks a line, so they don't count when comparing it.
    @Test func comparesCommandLinesWithoutSpaces() {
        // 日 didn't fit at the end of the first row, which was left with a blank cell.
        let screen = rows(["~/a/long/dir  ", "日 ❯ ls", "x"], from: 0, wrapped: [1])
        let found = CommandBlocks.relocate(commands: [("ls", "~/a/long/dir 日 ❯ ls")], in: screen, lastRow: 2, promptLines: 1)
        #expect(found.first??.prompt == 0)
    }

    /// Blocks saved before they kept their command line still load.
    @Test func decodesBlocksWithoutTheirCommandLine() throws {
        let block = try JSONDecoder().decode(CommandBlocks.Block.self, from: Data(#"{"prompt":4,"output":5}"#.utf8))
        #expect(block == .init(prompt: 4, output: 5))
    }

    @Test func replacesItsBlocks() {
        var blocks = CommandBlocks(limit: 2)
        blocks.record(.init(prompt: 10, output: 11))
        blocks.replace(with: [.init(prompt: 0, output: 1), .init(prompt: 2, output: 3), .init(prompt: 5, output: 6)])
        #expect(blocks.blocks == [.init(prompt: 2, output: 3), .init(prompt: 5, output: 6)])
    }

    @Test func findsTheCurrentPromptsStart() {
        let screen = rows(["out", "", "chips", "", "❯ long command that", "wraps"], from: 10, wrapped: [15])
        #expect(CommandBlocks.promptStart(cursorRow: 15, in: screen, promptLines: 4) == 11)
        #expect(CommandBlocks.promptStart(cursorRow: 99, in: screen, promptLines: 2) == 98)
        // A line of the prompt too long for one row.
        let narrow = rows(["out", "", "~/a/very/long/", "path main", "", "❯ ls"], from: 0, wrapped: [3])
        #expect(CommandBlocks.promptStart(cursorRow: 5, in: narrow, promptLines: 4) == 1)
        // Its start already gone from the rows given.
        #expect(CommandBlocks.promptStart(cursorRow: 5, in: narrow, promptLines: 7) == -2)
    }

    @Test func outputRunsToTheNextPromptOrTheGivenEnd() {
        var blocks = CommandBlocks()
        blocks.record(.init(prompt: 0, output: 2))
        blocks.record(.init(prompt: 6, output: 8))
        #expect(blocks.outputRange(of: 0, end: 30) == 2..<6)
        #expect(blocks.outputRange(of: 1, end: 12) == 8..<12)
        #expect(blocks.outputRange(of: 1, end: 8) == nil, "a command that printed nothing")
        #expect(blocks.outputRange(of: 5, end: 30) == nil)
        #expect(blocks.index(containing: 4) == 0)
        #expect(blocks.index(containing: 7) == 1)
        #expect(blocks.index(containing: -1) == nil)
    }

    @Test func startsOverWhenHistoryIsClearedAndStaysBounded() {
        var blocks = CommandBlocks(limit: 3)
        for prompt in stride(from: 0, to: 50, by: 5) { blocks.record(.init(prompt: prompt, output: prompt + 1)) }
        #expect(blocks.blocks.map(\.prompt) == [35, 40, 45])
        blocks.record(.init(prompt: 2, output: 3))
        #expect(blocks.blocks == [.init(prompt: 2, output: 3)])
    }
}
