import Foundation

/// One command that ran, as Codec saw it, or as the shell's history file has it.
public struct HistoryEntry: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// Recorded by Codec, with where it ran and how it went.
        case codec
        /// Read from the shell's history file: the command and, at best, when.
        case shell
    }

    public var command: String
    public var date: Date
    public var directory: String?
    public var exitCode: Int32?
    public var duration: TimeInterval?
    public var source: Source

    public init(command: String, date: Date, directory: String? = nil, exitCode: Int32? = nil,
                duration: TimeInterval? = nil, source: Source = .codec) {
        self.command = command
        self.date = date
        self.directory = directory
        self.exitCode = exitCode
        self.duration = duration
        self.source = source
    }
}

/// A command as the history lists it: every run of the same text merged into one.
public struct HistoryItem: Equatable, Sendable, Identifiable {
    public var id: String { command }
    public var command: String
    /// The most recent run. Where it ran and how it went come from the most recent run Codec saw.
    public var latest: HistoryEntry
    public var count: Int
    /// Where the query matched, in characters, for highlighting. Nil for fuzzy matches.
    public var match: Range<Int>?

    public var failed: Bool { (latest.exitCode ?? 0) != 0 }
}

/// Which commands to list.
public enum HistoryFilter: Equatable, Sendable {
    case all
    /// Commands that ran in this directory.
    case directory(String)
    /// Commands whose last run failed.
    case failed
}

/// Every command run, oldest first, and the ways to search it.
public struct CommandHistory: Equatable, Sendable {
    public private(set) var entries: [HistoryEntry]

    public init(entries: [HistoryEntry] = []) {
        self.entries = entries
    }

    /// Whether a command is worth keeping: not blank, and not hidden with a leading space, as zsh's
    /// HIST_IGNORE_SPACE does.
    public static func shouldRecord(_ command: String) -> Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !command.hasPrefix(" ")
    }

    /// Adds a run, keeping the list in time order (runs from several panes can finish out of order).
    public mutating func append(_ entry: HistoryEntry) {
        guard Self.shouldRecord(entry.command) else { return }
        guard let last = entries.last, entry.date < last.date else { return entries.append(entry) }
        var low = 0, high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if entries[middle].date <= entry.date { low = middle + 1 } else { high = middle }
        }
        entries.insert(entry, at: low)
    }

    /// Adds entries from elsewhere (the shell's history file), keeping the list in time order.
    public mutating func merge(_ others: [HistoryEntry]) {
        guard !others.isEmpty else { return }
        entries = (entries + others.filter { Self.shouldRecord($0.command) }).sorted { $0.date < $1.date }
    }

    /// Drops every run of a command.
    public mutating func forget(_ command: String) {
        entries.removeAll { $0.command == command }
    }

    /// Drops everything up to `date`.
    public mutating func clear(before date: Date) {
        entries.removeAll { $0.date <= date }
    }

    // MARK: Searching

    /// Commands matching `query`, best first.
    ///
    /// With no query, the most recent first. Otherwise, in tiers: commands that start with the query
    /// as typed, then ignoring case, then containing it, then a fuzzy match. Within a tier, those that
    /// ran in `directory` come first, then the most recent.
    public func items(matching query: String, filter: HistoryFilter = .all, directory: String? = nil,
                      limit: Int = 200) -> [HistoryItem] {
        var merged: [String: (item: HistoryItem, order: Int, directories: Set<String>)] = [:]
        var order = 0
        for entry in entries.reversed() {
            if var existing = merged[entry.command] {
                existing.item.count += 1
                if let directory = entry.directory { existing.directories.insert(directory) }
                // Fill in what the shell's file doesn't know from Codec's own record.
                if existing.item.latest.source == .shell, entry.source == .codec {
                    existing.item.latest.directory = entry.directory
                    existing.item.latest.exitCode = entry.exitCode
                    existing.item.latest.duration = entry.duration
                    existing.item.latest.source = .codec
                }
                merged[entry.command] = existing
            } else {
                merged[entry.command] = (HistoryItem(command: entry.command, latest: entry, count: 1, match: nil), order,
                                         entry.directory.map { [$0] } ?? [])
                order += 1
            }
        }
        var candidates = merged.values.filter { candidate in
            switch filter {
            case .all: true
            case .directory(let path): candidate.directories.contains(path)
            case .failed: candidate.item.failed
            }
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            candidates.sort { $0.order < $1.order }
            return candidates.prefix(limit).map(\.item)
        }
        let lowered = query.lowercased()
        let scored = candidates.compactMap { candidate -> (item: HistoryItem, tier: Int, score: Int, here: Bool, order: Int)? in
            var item = candidate.item
            let command = item.command
            let here = directory.map { candidate.directories.contains($0) } ?? false
            if command.hasPrefix(query) {
                item.match = 0..<query.count
                return (item, 0, 0, here, candidate.order)
            }
            let lower = command.lowercased()
            if lower.hasPrefix(lowered) {
                item.match = 0..<query.count
                return (item, 1, 0, here, candidate.order)
            }
            if let range = lower.range(of: lowered) {
                let start = lower.distance(from: lower.startIndex, to: range.lowerBound)
                item.match = start..<(start + query.count)
                return (item, 2, 0, here, candidate.order)
            }
            guard let score = FuzzyMatch.score(trimmed, in: command) else { return nil }
            return (item, 3, score, here, candidate.order)
        }
        return scored.sorted { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            if lhs.tier == 3, lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.here != rhs.here { return lhs.here }
            return lhs.order < rhs.order
        }
        .prefix(limit)
        .map(\.item)
    }

    // MARK: Codec's history file

    /// One line of Codec's history log: an entry, or an instruction that applies to what came before.
    public enum LogRecord: Codable, Equatable, Sendable {
        case entry(HistoryEntry)
        case forget(command: String)
        case clear(date: Date)

        private enum CodingKeys: String, CodingKey { case entry, forget, clear }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let entry = try container.decodeIfPresent(HistoryEntry.self, forKey: .entry) {
                self = .entry(entry)
            } else if let command = try container.decodeIfPresent(String.self, forKey: .forget) {
                self = .forget(command: command)
            } else {
                self = .clear(date: try container.decode(Date.self, forKey: .clear))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .entry(let entry): try container.encode(entry, forKey: .entry)
            case .forget(let command): try container.encode(command, forKey: .forget)
            case .clear(let date): try container.encode(date, forKey: .clear)
            }
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    /// A record as one line of JSON, newline included.
    public static func line(for record: LogRecord) -> Data {
        ((try? encoder.encode(record)) ?? Data()) + Data("\n".utf8)
    }

    /// Replays a log: entries in order, forgetting and clearing as recorded. Lines that don't parse
    /// (a write cut short) are skipped. Also returns when history was last cleared, if ever.
    public static func replay(_ data: Data) -> (entries: [HistoryEntry], forgotten: Set<String>, clearedAt: Date?) {
        var history = CommandHistory()
        var forgotten: Set<String> = []
        var clearedAt: Date?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let record = try? decoder.decode(LogRecord.self, from: Data(line)) else { continue }
            switch record {
            case .entry(let entry):
                history.entries.append(entry)
                forgotten.remove(entry.command)
            case .forget(let command):
                history.forget(command)
                forgotten.insert(command)
            case .clear(let date):
                history.clear(before: date)
                forgotten = []
                clearedAt = date
            }
        }
        return (history.entries, forgotten, clearedAt)
    }

    // MARK: zsh's history file

    /// Reads zsh's history file: plain lines, or `: <start>:<elapsed>;<command>` with
    /// EXTENDED_HISTORY. Multi-line commands continue with a trailing backslash.
    public static func parseZshHistory(_ data: Data, modified: Date = Date()) -> [HistoryEntry] {
        let text = String(decoding: unmetafy(data), as: UTF8.self)
        var entries: [HistoryEntry] = []
        var pending: String?
        var pendingDate: Date?
        func finish() {
            guard let command = pending else { return }
            entries.append(HistoryEntry(command: command, date: pendingDate ?? .distantPast, source: .shell))
            pending = nil
            pendingDate = nil
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            if pending != nil {
                // The previous line ended with a backslash: this one continues it.
                if line.hasSuffix("\\") {
                    line.removeLast()
                    pending! += "\n" + line
                    continue
                }
                pending! += "\n" + line
                finish()
                continue
            }
            guard !line.isEmpty else { continue }
            var date: Date?
            if line.hasPrefix(": "), let semicolon = line.firstIndex(of: ";") {
                let header = line[line.index(line.startIndex, offsetBy: 2)..<semicolon]
                if let start = header.split(separator: ":").first.flatMap({ TimeInterval($0) }) {
                    date = Date(timeIntervalSince1970: start)
                }
                line = String(line[line.index(after: semicolon)...])
            }
            pending = ""
            pendingDate = date
            if line.hasSuffix("\\") {
                line.removeLast()
                pending = line
                continue
            }
            pending = line
            finish()
        }
        finish()
        // Without timestamps, keep the file's order, just before it was last written.
        if entries.contains(where: { $0.date == .distantPast }) {
            let count = entries.count
            for index in entries.indices where entries[index].date == .distantPast {
                entries[index].date = modified.addingTimeInterval(-Double(count - index))
            }
        }
        return entries
    }

    /// zsh writes bytes 0x83 and up as 0x83 followed by the byte xor 0x20.
    static func unmetafy(_ data: Data) -> Data {
        guard data.contains(0x83) else { return data }
        var result = Data(capacity: data.count)
        var meta = false
        for byte in data {
            if meta {
                result.append(byte ^ 0x20)
                meta = false
            } else if byte == 0x83 {
                meta = true
            } else {
                result.append(byte)
            }
        }
        return result
    }
}

extension Formatting {
    /// When something happened, briefly: `now`, `5m`, `3h`, `Yesterday`, `Mon`, `Mar 4`, `Mar 4, 2024`.
    public static func relativeTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600))h" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if seconds < 6 * 86_400 {
            formatter.dateFormat = "EEE"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            formatter.dateFormat = "MMM d"
        } else {
            formatter.dateFormat = "MMM d, yyyy"
        }
        return formatter.string(from: date)
    }
}
