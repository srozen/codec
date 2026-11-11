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
    public struct Block: Codable, Equatable, Sendable {
        /// The first row of the command's prompt.
        public var prompt: Int
        /// The first row after the command line, where output begins.
        public var output: Int
        /// The command line as it was found, the end of the prompt and the command, so it can be told
        /// from output that happens to end with the same command. Nil when not known.
        public var commandLine: String?

        public init(prompt: Int, output: Int, commandLine: String? = nil) {
            self.prompt = prompt
            self.output = output
            self.commandLine = commandLine
        }
    }

    /// A command's rows, from its prompt to the end of its output, to set it apart on screen.
    public struct Span: Equatable, Sendable {
        public var rows: Range<Int>
        /// Every other command, counted from the first one run: the ones that get a shade.
        public var isAlternate: Bool

        public init(rows: Range<Int>, isAlternate: Bool) {
            self.rows = rows
            self.isAlternate = isAlternate
        }
    }

    public private(set) var blocks: [Block] = []
    /// Older blocks are dropped; they've long scrolled out of the scrollback anyway.
    public let limit: Int
    /// How many commands came before the first block, so that dropping the oldest ones doesn't turn
    /// every other command into the one that isn't.
    private var firstNumber = 0

    public init(limit: Int = 2_000) {
        self.limit = limit
    }

    /// Records a command that was just submitted.
    public mutating func record(_ block: Block) {
        // Rows only grow; going back means the history was cleared.
        if let last = blocks.last, block.prompt <= last.prompt { blocks.removeAll() }
        blocks.append(block)
        if blocks.count > limit {
            firstNumber += blocks.count - limit
            blocks.removeFirst(blocks.count - limit)
        }
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
    ///
    /// Any line can end with the command, its output's too: `ls` printing `Pictures  Tools`, or `cat list`
    /// printing `wildcat list`. That's harmless while the output hasn't started, as when a command is first
    /// found, but not when finding it again later. Then `line`, the command line as first found, must
    /// match too. Older prompts' ends aren't marked anywhere, only the current one's, so the line's text
    /// is what tells the prompt apart from output.
    public static func locate(command: String, line: String? = nil, in rows: [ScreenRow], cursorRow: Int,
                              promptLines: Int) -> Block? {
        let wanted = command.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        let candidates = rows.filter { $0.row <= cursorRow }
        // Logical lines, newest first: soft-wrapped rows joined.
        var index = candidates.count - 1
        while index >= 0 {
            var first = index
            while first > 0, candidates[first].isWrapped { first -= 1 }
            let text = trimmingTrailingSpace(candidates[first...index].map(\.text).joined())
            if text.hasSuffix(wanted), line.map({ sameLine(text, $0) }) ?? true {
                return Block(prompt: candidates[first].row - max(promptLines - 1, 0), output: candidates[index].row + 1,
                             commandLine: String(text))
            }
            index = first - 1
        }
        return nil
    }

    /// Replaces every block, after they were found again with `relocate`. `dropped` is how many of the
    /// oldest weren't found.
    public mutating func replace(with blocks: [Block], dropped: Int = 0) {
        firstNumber += dropped + max(blocks.count - limit, 0)
        self.blocks = Array(blocks.suffix(limit))
    }

    /// The commands with rows among `shown`, oldest first. Each runs to the next one's prompt, and the
    /// newest to `end`: the first row of the prompt the shell is waiting at, or past the last line while
    /// a command runs. `waitingPrompt`, that prompt's rows, comes last, as the command it's about to be.
    ///
    /// Nothing is printed past `end`, so a block that reaches further isn't there anymore: the screen was
    /// cleared under it. It's left out, with the ones after it.
    public func spans(overlapping shown: Range<Int>, end: Int, waitingPrompt: Range<Int>? = nil) -> [Span] {
        let live = blocks.prefix { $0.output <= end }
        var spans: [Span] = []
        for (index, block) in live.enumerated() {
            let upper = index + 1 < live.count ? live[index + 1].prompt : end
            guard block.prompt < upper else { continue }
            spans.append(Span(rows: block.prompt..<upper, isAlternate: (firstNumber + index) % 2 == 1))
        }
        if let waitingPrompt, !waitingPrompt.isEmpty {
            spans.append(Span(rows: waitingPrompt, isAlternate: (firstNumber + live.count) % 2 == 1))
        }
        return spans.filter { $0.rows.overlaps(shown) }
    }

    /// Drops the blocks whose command line isn't where it was found anymore: the screen was cleared under
    /// them, by `clear` or ⌃L. `rows` is the screen, and only says so about the command lines on it or
    /// below it; the ones above are in the scrollback, which stays as it was.
    public mutating func forgetBlocksGone(from rows: [ScreenRow]) {
        guard let top = rows.first?.row else { return }
        blocks.removeAll { block in
            guard let line = block.commandLine, block.output - 1 >= top else { return false }
            return Self.locate(command: line, line: line, in: rows, cursorRow: block.output - 1, promptLines: 1)?.output
                != block.output
        }
    }

    /// Finds commands' blocks again after their rows moved, as they do when the terminal rewraps its lines
    /// on a resize. `commands` are oldest first, each with its command line as first found (see `locate`);
    /// each is looked for above the one after it, starting from `lastRow`. Nil for a command that isn't on
    /// screen anymore.
    public static func relocate(commands: [(command: String, line: String?)], in rows: [ScreenRow], lastRow: Int,
                                promptLines: Int) -> [Block?] {
        var found: [Block?] = []
        var below = lastRow
        for (command, line) in commands.reversed() {
            let block = locate(command: command, line: line, in: rows, cursorRow: below, promptLines: promptLines)
            if let block { below = block.prompt - 1 }
            found.append(block)
        }
        return found.reversed()
    }

    /// The first row of the prompt whose command line contains `cursorRow`.
    public static func promptStart(cursorRow: Int, in rows: [ScreenRow], promptLines: Int) -> Int {
        guard var position = rows.firstIndex(where: { $0.row == cursorRow }) else { return cursorRow - max(promptLines - 1, 0) }
        while position > 0, rows[position].isWrapped { position -= 1 }
        // Up a line at a time: a long line of the prompt can take more than one row.
        var remaining = max(promptLines - 1, 0)
        while remaining > 0, position > 0 {
            position -= 1
            while position > 0, rows[position].isWrapped { position -= 1 }
            remaining -= 1
        }
        return rows[position].row - remaining
    }

    /// Rewrapping keeps a line's text and only breaks it into rows elsewhere, but where it breaks can add
    /// or drop a blank cell, as when a wide character doesn't fit at a row's end. So spaces don't count.
    private static func sameLine(_ text: Substring, _ line: String) -> Bool {
        text.filter { !$0.isWhitespace } == line.filter { !$0.isWhitespace }
    }

    private static func trimmingTrailingSpace(_ text: String) -> Substring {
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
        return text[..<end]
    }
}
