import Foundation

/// What a command printed, kept when it finished so it can be read after it has scrolled out of the
/// scrollback or the buffer was cleared. Very long output keeps its start and its end.
public struct CapturedOutput: Codable, Equatable, Sendable {
    public var text: String
    /// How many lines the command printed, including any left out.
    public var lineCount: Int
    /// Lines left out of the middle of `text`.
    public var omitted: Int
    /// Some of the output had already left the scrollback when the command finished.
    public var lostEarlier: Bool

    public static let headLines = 200
    public static let tailLines = 4_800

    public init(lines: [String], lostEarlier: Bool = false, head: Int = headLines, tail: Int = tailLines) {
        var lines = lines
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        lineCount = lines.count
        self.lostEarlier = lostEarlier
        if lines.count > head + tail {
            omitted = lines.count - head - tail
            text = (lines.prefix(head) + ["… \(omitted) lines …"] + lines.suffix(tail)).joined(separator: "\n")
        } else {
            omitted = 0
            text = lines.joined(separator: "\n")
        }
    }

    public var isEmpty: Bool { lineCount == 0 }

    /// The last line with something on it: usually the verdict ("Build complete", "3 failed").
    public var summary: String? {
        var end = text.endIndex
        while end > text.startIndex {
            let start = text[..<end].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            let line = text[start..<end].trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { return line }
            guard start > text.startIndex else { break }
            end = text.index(before: start)
        }
        return nil
    }

    /// The first line holding `query`, ignoring case, and how far into the output it is.
    public func firstLine(matching query: String) -> (line: String, index: Int)? {
        guard let expression = TextSearch.expression(for: query, options: FindOptions()) else { return nil }
        return firstMatch(of: expression).map { ($0.line, $0.index) }
    }

    /// The first line `expression` matches in, with the lines around it.
    public func firstMatch(of expression: NSRegularExpression) -> OutputMatch? {
        let string = text as NSString
        let found = expression.rangeOfFirstMatch(in: text, range: NSRange(location: 0, length: string.length))
        guard found.location != NSNotFound, found.length > 0 else { return nil }
        let lineRange = string.lineRange(for: NSRange(location: found.location, length: 0))
        let index = string.substring(to: lineRange.location).utf16.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        let line = string.substring(with: lineRange).trimmingCharacters(in: .newlines) as NSString
        let start = min(found.location - lineRange.location, line.length)
        let end = min(NSMaxRange(found) - lineRange.location, line.length)
        // Counted in characters, in the line without the spaces around it.
        let indent = (line as String).prefix { $0.isWhitespace }.count
        let trimmed = (line as String).trimmingCharacters(in: .whitespaces)
        let lower = min(max(line.substring(to: start).count - indent, 0), trimmed.count)
        let upper = min(lower + line.substring(with: NSRange(location: start, length: end - start)).count, trimmed.count)
        /// The nearest line with something on it, going up or down from the one at `location`.
        func neighbor(_ location: Int, up: Bool) -> String? {
            var location = location
            while location >= 0, location < string.length {
                let range = string.lineRange(for: NSRange(location: location, length: 0))
                let text = string.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
                location = up ? range.location - 1 : NSMaxRange(range)
            }
            return nil
        }
        return OutputMatch(line: trimmed, index: index,
                           range: lower..<upper,
                           before: neighbor(lineRange.location - 1, up: true),
                           after: neighbor(NSMaxRange(lineRange), up: false))
    }
}

/// A line of a command's output that holds what was searched for.
public struct OutputMatch: Equatable, Sendable {
    /// The line, without the spaces around it.
    public var line: String
    /// How far into the output it is, from 0.
    public var index: Int
    /// Where the match is in `line`, in characters.
    public var range: Range<Int>
    /// The nearest lines above and below it with something on them.
    public var before: String?
    public var after: String?

    public init(line: String, index: Int, range: Range<Int>, before: String? = nil, after: String? = nil) {
        self.line = line
        self.index = index
        self.range = range
        self.before = before
        self.after = after
    }

    /// The line from a little before the match, so a narrow list still shows the match: a long
    /// line's start gives way to "…".
    public func excerpt(leading: Int = 16) -> String {
        guard range.lowerBound > leading + 1 else { return line }
        return "…" + line.dropFirst(range.lowerBound - leading)
    }
}

/// What the Commands sidebar filters by: text, matched as Find's options say, and whether to keep
/// failed commands only.
public struct TimelineFilter: Equatable, Sendable {
    public var query: String
    public var options: FindOptions
    public var failedOnly: Bool

    public init(query: String = "", options: FindOptions = FindOptions(), failedOnly: Bool = false) {
        self.query = query
        self.options = options
        self.failedOnly = failedOnly
    }

    /// The query without the spaces around it.
    public var text: String { query.trimmingCharacters(in: .whitespaces) }

    /// What finds the query; nil when there's none, or it isn't a valid pattern.
    public var expression: NSRegularExpression? { TextSearch.expression(for: text, options: options) }

    /// There's a query, but it isn't a valid regular expression.
    public var isInvalid: Bool { !text.isEmpty && expression == nil }

    func matchesCommand(_ command: String, expression: NSRegularExpression) -> Bool {
        expression.rangeOfFirstMatch(in: command, range: NSRange(location: 0, length: (command as NSString).length)).length > 0
    }
}

/// One command run in a pane: what it was, where and when it ran, how it ended, where it is in the
/// scrollback and what it printed.
public struct TimelineEntry: Identifiable, Codable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case running
        case succeeded
        case failed(Int32)
    }

    public let id: Int
    /// The whole command, every line.
    public var command: String
    /// The command line as zsh reported it when it started: its first line, which is what's on screen.
    public var screenCommand: String
    public var directory: String
    public var started: Date
    public var duration: TimeInterval?
    public var exitCode: Int32?
    /// Where it is in the terminal. Nil once it's known to be gone (the buffer was cleared).
    public var block: CommandBlocks.Block?
    public var output: CapturedOutput?
    /// It switched to the alternate screen (vim, less, htop), so it left nothing in the scrollback.
    public var fullScreen = false
    /// How long it usually takes, as known when it started; see `UsualDuration`.
    public var usualDuration: TimeInterval?
    /// The Python environment and tool versions it ran with, when there were any.
    public var toolchain: Toolchain?

    public init(id: Int, command: String, screenCommand: String? = nil, directory: String, started: Date,
                block: CommandBlocks.Block?) {
        self.id = id
        self.command = command
        self.screenCommand = screenCommand ?? String(command.prefix { $0 != "\n" })
        self.directory = directory
        self.started = started
        self.block = block
    }

    public var status: Status {
        guard let exitCode else { return .running }
        return exitCode == 0 ? .succeeded : .failed(exitCode)
    }

    public var isRunning: Bool { exitCode == nil }

    public var failed: Bool {
        if case .failed = status { return true }
        return false
    }
}

/// The commands run in one pane, oldest first.
public struct CommandTimeline: Codable, Equatable, Sendable {
    public private(set) var entries: [TimelineEntry] = []
    private var nextID = 1
    /// Entries past this many are dropped, oldest first.
    public let limit: Int
    /// Output kept across all entries, in UTF-8 bytes; older entries lose their output first.
    public let outputBudget: Int

    public init(limit: Int = 1_000, outputBudget: Int = 24 << 20) {
        self.limit = limit
        self.outputBudget = outputBudget
    }

    public var running: TimelineEntry? {
        entries.last.flatMap { $0.isRunning ? $0 : nil }
    }

    public func entry(id: Int) -> TimelineEntry? {
        entries.last { $0.id == id }
    }

    /// A command started. Anything still marked running ended without a report (the shell was killed).
    @discardableResult
    public mutating func begin(command: String, screenCommand: String? = nil, directory: String, started: Date,
                               block: CommandBlocks.Block?, usualDuration: TimeInterval? = nil,
                               toolchain: Toolchain? = nil) -> Int {
        abandonRunning()
        let id = nextID
        nextID += 1
        var entry = TimelineEntry(id: id, command: command, screenCommand: screenCommand, directory: directory,
                                  started: started, block: block)
        entry.usualDuration = usualDuration
        entry.toolchain = toolchain.flatMap { $0.isEmpty ? nil : $0 }
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        return id
    }

    /// Fills in the running command's full text, which zsh reports just after it starts.
    public mutating func updateRunningCommand(_ command: String) {
        guard let index = entries.indices.last, entries[index].isRunning, !command.isEmpty else { return }
        entries[index].command = command
    }

    /// The running command's usual time, once its whole text is known.
    public mutating func setRunningUsualDuration(_ usual: TimeInterval?) {
        guard let index = entries.indices.last, entries[index].isRunning else { return }
        entries[index].usualDuration = usual
    }

    public mutating func markRunningFullScreen() {
        guard let index = entries.indices.last, entries[index].isRunning, !entries[index].fullScreen else { return }
        entries[index].fullScreen = true
    }

    /// The running command finished.
    public mutating func finish(exitCode: Int32, duration: TimeInterval, output: CapturedOutput?) {
        guard let index = entries.indices.last, entries[index].isRunning else { return }
        entries[index].exitCode = exitCode
        entries[index].duration = duration
        entries[index].output = output
        trimOutput()
    }

    /// Keeps what a finished command printed, once it's known where its output ends.
    public mutating func setOutput(_ output: CapturedOutput, of id: Int) {
        guard let index = entries.lastIndex(where: { $0.id == id }) else { return }
        entries[index].output = output
        trimOutput()
    }

    /// The shell went away mid-command: whatever was running won't report back.
    public mutating func abandonRunning() {
        guard let index = entries.indices.last, entries[index].isRunning else { return }
        entries[index].exitCode = -1
    }

    /// The scrollback was cleared: no entry can be found on screen anymore.
    public mutating func forgetBlocks() {
        for index in entries.indices where entries[index].block != nil { entries[index].block = nil }
    }

    /// Forgets one entry's place on screen, when it turned out not to be there anymore.
    public mutating func forgetBlock(of id: Int) {
        guard let index = entries.lastIndex(where: { $0.id == id }) else { return }
        entries[index].block = nil
    }

    /// Moves commands to where they were found again; see `CommandBlocks.relocate`.
    public mutating func setBlocks(_ blocks: [Int: CommandBlocks.Block?]) {
        for index in entries.indices {
            if let block = blocks[entries[index].id] { entries[index].block = block }
        }
    }

    /// Entries whose command or output holds `query` (ignoring case), optionally only failed ones.
    public func entries(matching query: String, failedOnly: Bool = false) -> [TimelineEntry] {
        entries(matching: TimelineFilter(query: query, failedOnly: failedOnly))
    }

    /// Entries the filter lets through: whose command or output matches, as Find's options say. None
    /// when the query isn't a valid pattern.
    public func entries(matching filter: TimelineFilter) -> [TimelineEntry] {
        let expression = filter.expression
        if expression == nil, !filter.text.isEmpty { return [] }
        return entries.filter { entry in
            if filter.failedOnly, !entry.failed { return false }
            guard let expression else { return true }
            return filter.matchesCommand(entry.command, expression: expression) || entry.output?.firstMatch(of: expression) != nil
        }
    }

    /// For keeping it with a transcript of the scrollback that starts at `firstRow`: places are
    /// counted from there, commands that had scrolled out of it lose theirs, and a command still
    /// running is marked as ended without a report.
    public func rebased(firstRow: Int) -> CommandTimeline {
        var copy = self
        copy.abandonRunning()
        for index in copy.entries.indices {
            guard let block = copy.entries[index].block else { continue }
            copy.entries[index].block = block.prompt >= firstRow
                ? CommandBlocks.Block(prompt: block.prompt - firstRow, output: block.output - firstRow,
                                      commandLine: block.commandLine) : nil
        }
        return copy
    }

    private mutating func trimOutput() {
        var total = 0
        for index in entries.indices.reversed() {
            guard let output = entries[index].output else { continue }
            total += output.text.utf8.count
            if total > outputBudget { entries[index].output = nil }
        }
    }
}
