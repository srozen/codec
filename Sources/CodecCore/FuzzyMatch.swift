/// Subsequence matching for the command palette, preferring word starts and consecutive characters.
public enum FuzzyMatch {
    /// A score for how well `query` matches `text`, or nil if it doesn't. Higher is better.
    /// An empty query matches everything with a score of 0.
    public static func score(_ query: String, in text: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let haystack = Array(text.lowercased())
        var score = 0
        var matched = 0
        var previous = -2
        for (index, character) in haystack.enumerated() where matched < needle.count {
            guard character == needle[matched] else { continue }
            score += 1
            if index == previous + 1 { score += 3 }
            if index == 0 || !haystack[index - 1].isLetter { score += 5 }
            previous = index
            matched += 1
        }
        guard matched == needle.count else { return nil }
        // Shorter candidates win ties.
        return score * 100 - haystack.count
    }

    /// `items` matching `query`, best first. Keeps the original order for an empty query.
    public static func rank<T>(_ items: [T], by query: String, key: (T) -> String) -> [T] {
        var scored: [(item: T, score: Int, offset: Int)] = []
        for (offset, item) in items.enumerated() {
            if let score = score(query, in: key(item)) { scored.append((item, score, offset)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
        return scored.map(\.item)
    }
}
