import Foundation

/// Which lines of a text differ from an earlier version of it, for the marks in the editor's gutter.
///
/// Lines are numbered from 0 in the new text, as the editor shows them: a text ending with a newline
/// has an empty last line. A run of changes that both removes and adds lines marks the added ones as
/// modified; a run that only adds marks them added; a run that only removes leaves a deletion between
/// the lines around it.
public struct LineChanges: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case added, modified
    }

    /// The added and modified lines.
    public private(set) var lines: [Int: Kind] = [:]
    /// Lines that had lines removed just above them. When lines were removed from the very end, it's
    /// the line count: the removal is below the last line.
    public private(set) var deletions: Set<Int> = []

    public var isEmpty: Bool { lines.isEmpty && deletions.isEmpty }

    /// How many differences the diff follows before giving up on finding the lines in common. Past
    /// it, the rest of the text is one change: the cost of the diff grows with the square of its
    /// differences, and that many is a rewrite anyway.
    public static let differenceLimit = 1_000

    public init() {}

    public init(lines: [Int: Kind], deletions: Set<Int> = []) {
        self.lines = lines
        self.deletions = deletions
    }

    /// The changes that turn `old` into `new`.
    public init(from old: String, to new: String) {
        guard old != new else { return }
        // Lines become numbers, so comparing them is cheap. A carriage return before the newline is
        // ignored: git may keep a file with plain newlines that's checked out with CRLF. (Split by
        // scalars: "\r\n" is a single Character.)
        var ids: [Substring: Int] = [:]
        func numbered(_ text: String) -> [Int] {
            text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { scalars in
                let line = Substring(scalars.last == "\r" ? scalars.dropLast() : scalars)
                if let id = ids[line] { return id }
                let id = ids.count
                ids[line] = id
                return id
            }
        }
        let a = numbered(old), b = numbered(new)

        // What's the same at either end needs no diff, and is all of it for most edits.
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let oldMiddle = Array(a[prefix..<(a.count - suffix)])
        let newMiddle = Array(b[prefix..<(b.count - suffix)])

        guard let (removed, inserted) = Self.difference(from: oldMiddle, to: newMiddle, limit: Self.differenceLimit) else {
            record(removed: oldMiddle.count, added: newMiddle.count, at: prefix)
            return
        }
        // Lines neither removed nor inserted are the same on both sides, in order: walk both texts
        // together, and each run of changes between two common lines is one change.
        var i = 0, j = 0
        while i < oldMiddle.count || j < newMiddle.count {
            var removedCount = 0, addedCount = 0
            while i + removedCount < oldMiddle.count, removed[i + removedCount] { removedCount += 1 }
            while j + addedCount < newMiddle.count, inserted[j + addedCount] { addedCount += 1 }
            if removedCount == 0, addedCount == 0 {
                i += 1
                j += 1
                continue
            }
            record(removed: removedCount, added: addedCount, at: prefix + j)
            i += removedCount
            j += addedCount
        }
    }

    private mutating func record(removed: Int, added: Int, at line: Int) {
        if added == 0 {
            if removed > 0 { deletions.insert(line) }
            return
        }
        let kind: Kind = removed == 0 ? .added : .modified
        for index in line..<(line + added) { lines[index] = kind }
    }

    /// Myers' diff: which elements of `a` are removed and which of `b` inserted, as flags, or nil if
    /// it takes more than `limit` of them.
    static func difference(from a: [Int], to b: [Int], limit: Int) -> (removed: [Bool], inserted: [Bool])? {
        let n = a.count, m = b.count
        var removed = [Bool](repeating: false, count: n)
        var inserted = [Bool](repeating: false, count: m)
        if n == 0 || m == 0 {
            return (removed.map { _ in true }, inserted.map { _ in true })
        }
        let maximum = min(n + m, limit)
        let offset = maximum + 1
        // v[k] is how far along `a` the furthest path on diagonal k (x - y) has got.
        var v = [Int](repeating: 0, count: 2 * maximum + 3)
        // What v held on each diagonal -d...d before step d, to walk the path back.
        var trace: [[Int]] = []
        for d in 0...maximum {
            trace.append(Array(v[(offset - d)...(offset + d)]))
            for k in stride(from: -d, through: d, by: 2) {
                var x = k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n, y < m, a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[offset + k] = x
                guard x >= n, y >= m else { continue }
                // Back from the end: each step came down (an insertion) or across (a removal) from
                // the furthest path on a neighboring diagonal, then along a run of common elements.
                var x0 = n, y0 = m
                for step in stride(from: d, to: 0, by: -1) {
                    let before = trace[step]
                    func at(_ diagonal: Int) -> Int { before[diagonal + step] }
                    let k = x0 - y0
                    let down = k == -step || (k != step && at(k - 1) < at(k + 1))
                    let previousK = down ? k + 1 : k - 1
                    let previousX = at(previousK), previousY = previousX - previousK
                    if down { inserted[previousY] = true } else { removed[previousX] = true }
                    x0 = previousX
                    y0 = previousY
                }
                return (removed, inserted)
            }
        }
        return nil
    }
}
