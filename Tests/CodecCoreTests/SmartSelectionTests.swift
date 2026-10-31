import Testing
@testable import CodecCore

@Suite("SmartSelection")
struct SmartSelectionTests {
    /// The token selected by double-clicking the first occurrence of `target` in `line`.
    private func pick(_ line: String, clicking target: String, offset: Int = 0) -> String? {
        guard let range = line.range(of: target) else { return nil }
        return SmartSelection.token(in: line, at: line.distance(from: line.startIndex, to: range.lowerBound) + offset)
    }

    @Test(arguments: [
        ("contact jane.doe@example.com today", "doe", "jane.doe@example.com"),
        ("listening on 192.168.1.20:8080", "168", "192.168.1.20:8080"),
        ("Sources/App/Main.swift:42:7: error: boom", "Main", "Sources/App/Main.swift:42:7"),
        ("run with --output-dir=/tmp/out please", "output", "--output-dir=/tmp/out"),
        ("echo $HOME_DIR/bin", "HOME", "$HOME_DIR/bin"),
        ("commit 3f9a2c41d0e7b6a5 (HEAD -> main)", "9a2", "3f9a2c41d0e7b6a5"),
        ("(see https://example.com/a?b=1)", "example", "https://example.com/a?b=1"),
        ("open 'My File.txt' now", "File", "File.txt"),
        ("value: \"quoted-thing\",", "quoted", "quoted-thing"),
        ("call foo(bar) twice", "foo", "foo(bar)"),
        ("│ cell-value │", "cell", "cell-value"),
        ("<https://swift.org>", "swift", "https://swift.org"),
        ("The end.", "end", "end"),
        ("ls ~/Library/Logs;", "Library", "~/Library/Logs"),
        ("a|b", "b", "b"),
        ("[v1.2.3-beta]", "1.2", "v1.2.3-beta"),
    ])
    func selectsWholeTokens(line: String, clicking target: String, expected: String) {
        #expect(pick(line, clicking: target) == expected)
    }

    @Test func clickingWhitespaceOrAFrameSelectsNothing() {
        #expect(SmartSelection.token(in: "a  b", at: 1) == nil)
        #expect(SmartSelection.token(in: "│ x │", at: 0) == nil)
        #expect(SmartSelection.token(in: "", at: 0) == nil)
        #expect(SmartSelection.token(in: "abc", at: 9) == nil)
    }

    /// Clicking a wrapper that gets peeled (a bracket or quote) selects nothing rather than something
    /// that doesn't include the click.
    @Test func clickingAPeeledWrapperSelectsNothing() {
        #expect(SmartSelection.token(in: "(value)", at: 0) == nil)
        #expect(SmartSelection.token(in: "end.", at: 3) == nil)
    }
}
