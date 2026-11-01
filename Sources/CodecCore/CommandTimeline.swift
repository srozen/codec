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
        guard !query.isEmpty else { return nil }
        var index = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                return (line.trimmingCharacters(in: .whitespaces), index)
            }
            index += 1
        }
        return nil
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
                               block: CommandBlocks.Block?, usualDuration: TimeInterval? = nil) -> Int {
        abandonRunning()
        let id = nextID
        nextID += 1
        var entry = TimelineEntry(id: id, command: command, screenCommand: screenCommand, directory: directory,
                                  started: started, block: block)
        entry.usualDuration = usualDuration
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
        let query = query.trimmingCharacters(in: .whitespaces)
        return entries.filter { entry in
            if failedOnly, !entry.failed { return false }
            guard !query.isEmpty else { return true }
            return entry.command.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || entry.output?.firstLine(matching: query) != nil
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
                ? CommandBlocks.Block(prompt: block.prompt - firstRow, output: block.output - firstRow) : nil
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
