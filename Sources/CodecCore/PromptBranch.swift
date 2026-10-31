/// Finds the git branch in a line of prompt, so clicking it can switch branches.
///
/// The branch is found by its text, which works for Codec's prompt and for prompts of your own
/// (`git:(main)`, `on  main`). It has to stand alone: `main` in `~/code/main` or `mainline` doesn't count.
public enum PromptBranch {
    /// Where `branch` is in `line`, with Codec's `⎇ ` before it and the `*` for uncommitted changes
    /// after it. When it shows more than once, the one marked `⎇` wins, then the last.
    public static func range(of branch: String, in line: [Character]) -> Range<Int>? {
        let wanted = Array(branch)
        guard !wanted.isEmpty, line.count >= wanted.count else { return nil }
        var found: [Range<Int>] = []
        for start in 0...(line.count - wanted.count) where Array(line[start..<(start + wanted.count)]) == wanted {
            let end = start + wanted.count
            if start > 0, isNameCharacter(line[start - 1]) { continue }
            if end < line.count, isNameCharacter(line[end]) { continue }
            found.append(start..<end)
        }
        guard let match = found.first(where: { isMarked($0, in: line) }) ?? found.last else { return nil }
        var lower = match.lowerBound, upper = match.upperBound
        if isMarked(match, in: line) { lower -= 2 }
        if upper < line.count, line[upper] == "*" { upper += 1 }
        return lower..<upper
    }

    private static func isMarked(_ range: Range<Int>, in line: [Character]) -> Bool {
        range.lowerBound >= 2 && line[range.lowerBound - 2] == "⎇" && line[range.lowerBound - 1] == " "
    }

    /// Characters a branch name can continue with; anything else ends it.
    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "-_./".contains(character)
    }
}
