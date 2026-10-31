/// What a double-click selects: the whole token under the pointer — a path, URL, email, `host:port`,
/// `file.swift:42:7`, `--flag=value`, `$VAR`, a hash — without the brackets, quotes or punctuation
/// around it.
public enum SmartSelection {
    /// The range to select for a double-click at `index` in `line`, or nil when the click isn't on a token.
    public static func range(in line: [Character], at index: Int) -> Range<Int>? {
        guard line.indices.contains(index), !isSeparator(line[index]) else { return nil }
        var lo = index, hi = index + 1
        while lo > 0, !isSeparator(line[lo - 1]) { lo -= 1 }
        while hi < line.count, !isSeparator(line[hi]) { hi += 1 }

        // Peel what wraps the token, one character at a time:
        // 1. an opening bracket or quote: with its partner if that ends the token, alone if it's unclosed;
        // 2. a closing bracket with no opener inside the token, as in "(see https://x.y/a)";
        // 3. trailing punctuation, as in "file.swift:42:" or "the end.".
        while lo < hi {
            let first = line[lo], last = line[hi - 1]
            if let partner = openers[first] {
                if hi - lo >= 2, last == partner {
                    lo += 1
                    hi -= 1
                    continue
                }
                if !line[(lo + 1)..<hi].contains(partner) {
                    lo += 1
                    continue
                }
            }
            if let opener = closers[last], count(opener, in: line[lo..<hi]) < count(last, in: line[lo..<hi]) {
                hi -= 1
                continue
            }
            if trailingPunctuation.contains(last) {
                hi -= 1
                continue
            }
            break
        }
        guard lo < hi, (lo..<hi).contains(index) else { return nil }
        return lo..<hi
    }

    /// The token at `index` in `line`, for strings.
    public static func token(in line: String, at index: Int) -> String? {
        let characters = Array(line)
        return range(in: characters, at: index).map { String(characters[$0]) }
    }

    private static let openers: [Character: Character] = ["(": ")", "[": "]", "{": "}", "<": ">", "\"": "\"", "'": "'", "`": "`"]
    private static let closers: [Character: Character] = [")": "(", "]": "[", "}": "{", ">": "<"]
    private static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", "\"", "'", "`"]

    private static func isSeparator(_ character: Character) -> Bool {
        if character.isWhitespace || character == "|" || character == "\0" { return true }
        // Box drawing and block elements frame text in TUIs and tables.
        guard let scalar = character.unicodeScalars.first else { return true }
        return (0x2500...0x259F).contains(scalar.value)
    }

    private static func count(_ character: Character, in slice: ArraySlice<Character>) -> Int {
        slice.reduce(0) { $0 + ($1 == character ? 1 : 0) }
    }
}
