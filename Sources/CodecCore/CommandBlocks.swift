/// One row of the terminal, as needed to find commands on screen.
public struct ScreenRow: Equatable, Sendable {
    /// SwiftTerm's scroll-invariant row number.
    public var row: Int
    public var text: String
    /// This row continues the previous one (a soft wrap).
    public var isWrapped: Bool

    public init(row: Int, text: String, isWrapped: Bool) {
        self.row = row
        self.text = text
        self.isWrapped = isWrapped
    }
}

/// Where each command's prompt and output begin, in the terminal's scroll-invariant row numbers, so a
/// command's output can be copied or selected after the fact.
///
/// Rows are found from content, not timing: the command line is the line that ends with the command
/// zsh reported, its prompt starts `promptLines - 1` rows above, and the output starts below it. So it
/// doesn't matter how far output has run by the time Codec looks.
public struct CommandBlocks: Equatable, Sendable {
    public struct Block: Equatable, Sendable {
        /// The first row of the command's prompt.
        public var prompt: Int
        /// The first row after the command line, where output begins.
        public var output: Int

        public init(prompt: Int, output: Int) {
            self.prompt = prompt
            self.output = output
        }
    }

    public private(set) var blocks: [Block] = []
    /// Older blocks are dropped; they've long scrolled out of the scrollback anyway.
    public let limit: Int

    public init(limit: Int = 2_000) {
        self.limit = limit
    }

    /// Records a command that was just submitted.
    public mutating func record(_ block: Block) {
        // Rows only grow; going back means the history was cleared.
        if let last = blocks.last, block.prompt <= last.prompt { blocks.removeAll() }
        blocks.append(block)
        if blocks.count > limit { blocks.removeFirst(blocks.count - limit) }
    }

    /// The output of block `index`, up to the next block's prompt or, for the newest, to `end`
    /// (the current prompt's first row, or past the last line while the command runs).
    public func outputRange(of index: Int, end: Int) -> Range<Int>? {
        guard blocks.indices.contains(index) else { return nil }
        let upper = index + 1 < blocks.count ? blocks[index + 1].prompt : end
        let start = blocks[index].output
        return start < upper ? start..<upper : nil
    }

    /// The block whose prompt, command or output contains `row`.
    public func index(containing row: Int) -> Int? {
        blocks.lastIndex { $0.prompt <= row }
    }

    /// Finds the command line that ends with `command` at or above `cursorRow`, and returns the block it
    /// opens. `promptLines` is how many lines the prompt has, its command line included.
    public static func locate(command: String, in rows: [ScreenRow], cursorRow: Int, promptLines: Int) -> Block? {
        let wanted = command.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        let candidates = rows.filter { $0.row <= cursorRow }
        // Logical lines, newest first: soft-wrapped rows joined.
        var index = candidates.count - 1
        while index >= 0 {
            var first = index
            while first > 0, candidates[first].isWrapped { first -= 1 }
            let text = candidates[first...index].map(\.text).joined()
            if trimmingTrailingSpace(text).hasSuffix(wanted) {
                return Block(prompt: candidates[first].row - max(promptLines - 1, 0), output: candidates[index].row + 1)
            }
            index = first - 1
        }
        return nil
    }

    /// Replaces every block, after they were found again with `relocate`.
    public mutating func replace(with blocks: [Block]) {
        self.blocks = Array(blocks.suffix(limit))
    }

    /// Finds commands' blocks again after their rows moved, as they do when the terminal rewraps its lines
    /// on a resize. `commands` are oldest first; each is looked for above the one after it, starting from
    /// `lastRow`. Nil for a command that isn't on screen anymore.
    public static func relocate(commands: [String], in rows: [ScreenRow], lastRow: Int, promptLines: Int) -> [Block?] {
        var found: [Block?] = []
        var below = lastRow
        for command in commands.reversed() {
            let block = locate(command: command, in: rows, cursorRow: below, promptLines: promptLines)
            if let block { below = block.prompt - 1 }
            found.append(block)
        }
        return found.reversed()
    }

    /// The first row of the prompt whose command line contains `cursorRow`.
    public static func promptStart(cursorRow: Int, in rows: [ScreenRow], promptLines: Int) -> Int {
        guard var position = rows.firstIndex(where: { $0.row == cursorRow }) else { return cursorRow - max(promptLines - 1, 0) }
        while position > 0, rows[position].isWrapped { position -= 1 }
        return rows[position].row - max(promptLines - 1, 0)
    }

    private static func trimmingTrailingSpace(_ text: String) -> Substring {
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
        return text[..<end]
    }
}
