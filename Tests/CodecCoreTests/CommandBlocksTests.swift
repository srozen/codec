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
        #expect(block == .init(prompt: 40, output: 44))
    }

    /// Output may already be on screen when Codec looks; the command line is found above it.
    @Test func ignoresOutputBelowTheCommandLine() {
        let screen = rows(["% echo hi", "hi", "% "], from: 7)
        #expect(CommandBlocks.locate(command: "echo hi", in: screen, cursorRow: 9, promptLines: 1) == .init(prompt: 7, output: 8))
    }

    @Test func joinsSoftWrappedCommandLines() {
        let screen = rows(["% echo aaaa", "aaaa bbb", "out"], from: 0, wrapped: [1])
        #expect(CommandBlocks.locate(command: "echo aaaaaaaa bbb", in: screen, cursorRow: 2, promptLines: 1) == .init(prompt: 0, output: 2))
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
        let found = CommandBlocks.relocate(commands: ["echo a", "ls -la /some/long/path", "echo a", "gone"], in: screen,
                                           lastRow: 36, promptLines: 1)
        #expect(found == [.init(prompt: 30, output: 31), .init(prompt: 32, output: 34), .init(prompt: 35, output: 36), nil])
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
