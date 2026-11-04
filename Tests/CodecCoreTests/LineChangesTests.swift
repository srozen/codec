import Testing
@testable import CodecCore

@Suite("Line changes")
struct LineChangesTests {
    @Test func theSameTextHasNoChanges() {
        #expect(LineChanges(from: "a\nb\n", to: "a\nb\n").isEmpty)
        #expect(LineChanges(from: "", to: "").isEmpty)
    }

    @Test func marksModifiedAddedAndDeletedLines() {
        #expect(LineChanges(from: "a\nb\nc\n", to: "a\nB\nc\n") == LineChanges(lines: [1: .modified]))
        #expect(LineChanges(from: "a\nc\n", to: "a\nb1\nb2\nc\n") == LineChanges(lines: [1: .added, 2: .added]))
        #expect(LineChanges(from: "a\nb\nc\n", to: "a\nc\n") == LineChanges(lines: [:], deletions: [1]))
        // An empty file has one empty line, which stays after the new one.
        #expect(LineChanges(from: "", to: "a\n") == LineChanges(lines: [0: .added]))
    }

    @Test func deletionsAtEitherEnd() {
        #expect(LineChanges(from: "a\nb\n", to: "b\n") == LineChanges(lines: [:], deletions: [0]))
        // Without a final newline, it's below the last line.
        #expect(LineChanges(from: "a\nb", to: "a") == LineChanges(lines: [:], deletions: [1]))
        // With one, above the empty line after it.
        #expect(LineChanges(from: "a\nb\n", to: "a\n") == LineChanges(lines: [:], deletions: [1]))
    }

    @Test func eachRunOfChangesIsMarkedOnItsOwn() {
        // Two lines become one, and a line is added at the end.
        let changes = LineChanges(from: "a\nb\nc\nd\ne", to: "a\nX\nd\ne\nf")
        #expect(changes == LineChanges(lines: [1: .modified, 4: .added]))
    }

    @Test func ignoresCarriageReturns() {
        #expect(LineChanges(from: "a\r\nb\r\n", to: "a\nb\n").isEmpty)
        #expect(LineChanges(from: "a\r\nb\r\n", to: "a\nc\n") == LineChanges(lines: [1: .modified]))
    }

    /// The diff keeps as many lines as the longest common subsequence has, and what it keeps is common.
    @Test func findsTheLongestCommonSubsequence() {
        var random = SeededRandom(seed: 42)
        for _ in 0..<300 {
            let a = (0..<Int.random(in: 0...12, using: &random)).map { _ in Int.random(in: 0...3, using: &random) }
            let b = (0..<Int.random(in: 0...12, using: &random)).map { _ in Int.random(in: 0...3, using: &random) }
            let (removed, inserted) = LineChanges.difference(from: a, to: b, limit: 100)!
            let keptA = a.indices.filter { !removed[$0] }.map { a[$0] }
            let keptB = b.indices.filter { !inserted[$0] }.map { b[$0] }
            #expect(keptA == keptB, "\(a) → \(b)")
            #expect(keptA.count == longestCommonSubsequence(a, b), "\(a) → \(b)")
        }
    }

    @Test func aRewriteBeyondTheLimitIsOneChange() {
        let old = (0..<1_200).map { "k\($0)" }
        // Every other line changes: more differences than the diff follows.
        let new = old.indices.map { $0.isMultiple(of: 2) ? old[$0] : "x\($0)" }
        let changes = LineChanges(from: old.joined(separator: "\n"), to: new.joined(separator: "\n"))
        #expect(changes.lines.count == 1_199)
        #expect(changes.lines.values.allSatisfy { $0 == .modified })
        #expect(changes.lines[0] == nil)

        // Under it, only the changed lines.
        let few = old.indices.map { $0.isMultiple(of: 100) && $0 > 0 ? "x\($0)" : old[$0] }
        #expect(Set(LineChanges(from: old.joined(separator: "\n"), to: few.joined(separator: "\n")).lines.keys)
            == Set(stride(from: 100, to: 1_200, by: 100)))
    }
}

private func longestCommonSubsequence(_ a: [Int], _ b: [Int]) -> Int {
    var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in a.indices {
        for j in b.indices {
            table[i + 1][j + 1] = a[i] == b[j] ? table[i][j] + 1 : max(table[i][j + 1], table[i + 1][j])
        }
    }
    return table[a.count][b.count]
}

/// The same numbers every run.
private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
