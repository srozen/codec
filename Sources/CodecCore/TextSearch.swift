import Foundation

/// How Find matches what's typed.
public struct FindOptions: Equatable, Sendable {
    public var caseSensitive: Bool
    public var regex: Bool
    public var wholeWord: Bool

    public init(caseSensitive: Bool = false, regex: Bool = false, wholeWord: Bool = false) {
        self.caseSensitive = caseSensitive
        self.regex = regex
        self.wholeWord = wholeWord
    }
}

/// Finding a query in lines of characters, as the terminal's Find does over its scrollback.
public enum TextSearch {
    /// The expression that finds `query`, or nil when it's empty or isn't a valid regular expression.
    public static func expression(for query: String, options: FindOptions) -> NSRegularExpression? {
        guard !query.isEmpty else { return nil }
        var pattern = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord { pattern = "\\b(?:\(pattern))\\b" }
        return try? NSRegularExpression(pattern: pattern, options: options.caseSensitive ? [] : [.caseInsensitive])
    }

    /// Where `expression` matches in a line, as offsets into `characters`. Empty matches are left out.
    public static func matches(of expression: NSRegularExpression, in characters: [Character]) -> [Range<Int>] {
        // Where each character starts in UTF-16, which the expression counts in, and where the line ends.
        var starts: [Int] = []
        starts.reserveCapacity(characters.count + 1)
        var offset = 0
        for character in characters {
            starts.append(offset)
            offset += character.utf16.count
        }
        starts.append(offset)
        return expression.matches(in: String(characters), range: NSRange(location: 0, length: offset)).compactMap { match in
            let range = match.range
            guard range.location != NSNotFound, range.length > 0 else { return nil }
            let lower = characterIndex(containing: range.location, starts: starts)
            let upper = characterIndex(containing: range.location + range.length - 1, starts: starts) + 1
            return lower..<upper
        }
    }

    /// The character a UTF-16 offset falls in.
    private static func characterIndex(containing offset: Int, starts: [Int]) -> Int {
        var low = 0, high = starts.count - 2
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }
}
