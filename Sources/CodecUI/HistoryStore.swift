import Foundation
import Combine
import CodecCore

/// Every window's command history: what Codec recorded, kept in an append-only log, plus what the
/// shell's history file holds, so commands from before Codec (or from other terminals) are there too.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var history = CommandHistory()

    /// Codec's log. Nil keeps history in memory only.
    private let logURL: URL?
    /// The shell's history file, as zsh reported it.
    private var shellFile: URL?
    private var shellFileModified: Date?
    private var shellEntries: [HistoryEntry] = []
    private var codecEntries: [HistoryEntry] = []
    private var forgotten: Set<String> = []
    private var clearedAt: Date?
    private var logLoaded = false
    private var loadTask: Task<Void, Never>?

    /// Logs past this many entries are rewritten without their oldest ones.
    static let limit = 50_000

    init(logURL: URL?, shellFile: URL? = nil) {
        self.logURL = logURL
        self.shellFile = shellFile
    }

    /// The store the app uses, in Application Support.
    static func standard() -> HistoryStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let shellFile = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".zsh_history")
        return HistoryStore(logURL: support?.appendingPathComponent("Codec/history.jsonl"), shellFile: shellFile)
    }

    // MARK: Loading

    /// Reads the log and the shell's file, off the main thread. Safe to call again; it only rereads
    /// the shell's file when it changed.
    func load() {
        guard loadTask == nil else { return }
        let logURL = logURL, shellFile = shellFile, needsLog = !logLoaded
        let knownModified = shellFileModified
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> (log: (entries: [HistoryEntry], forgotten: Set<String>, clearedAt: Date?)?, shell: [HistoryEntry]?, modified: Date?) in
                var log: (entries: [HistoryEntry], forgotten: Set<String>, clearedAt: Date?)?
                if needsLog, let logURL, let data = try? Data(contentsOf: logURL) {
                    log = CommandHistory.replay(data)
                }
                var shell: [HistoryEntry]?
                var modified: Date?
                if let shellFile {
                    // Not URL resource values: those are cached, and would miss changes.
                    modified = (try? FileManager.default.attributesOfItem(atPath: shellFile.path))?[.modificationDate] as? Date
                    if modified != knownModified, let data = try? Data(contentsOf: shellFile) {
                        shell = CommandHistory.parseZshHistory(data, modified: modified ?? Date())
                    }
                }
                return (log, shell, modified)
            }.value
            guard let self else { return }
            if let log = result.log {
                self.codecEntries = log.entries + self.codecEntries
                self.forgotten = log.forgotten
                self.clearedAt = log.clearedAt
            }
            self.logLoaded = true
            if let shell = result.shell {
                self.shellEntries = shell
                self.shellFileModified = result.modified
            }
            self.rebuild()
            self.loadTask = nil
        }
    }

    /// Waits for loading to finish, for tests.
    func loaded() async {
        await loadTask?.value
    }

    /// zsh said where its history file is.
    func useShellFile(_ url: URL) {
        guard url.standardizedFileURL != shellFile?.standardizedFileURL else { return }
        shellFile = url
        shellFileModified = nil
        load()
    }

    private func rebuild() {
        var merged = CommandHistory()
        codecEntries.forEach { merged.append($0) }
        let shell = shellEntries.filter { entry in
            !forgotten.contains(entry.command) && clearedAt.map { entry.date > $0 } ?? true
        }
        merged.merge(shell)
        if merged != history { history = merged }
    }

    // MARK: Changing it

    /// Keeps a command that just ran.
    func record(_ entry: HistoryEntry) {
        guard CommandHistory.shouldRecord(entry.command) else { return }
        codecEntries.append(entry)
        forgotten.remove(entry.command)
        append(.entry(entry))
        rebuild()
    }

    /// Removes every run of a command, including from what the shell's file shows.
    func forget(_ command: String) {
        codecEntries.removeAll { $0.command == command }
        forgotten.insert(command)
        append(.forget(command: command))
        rebuild()
    }

    /// Forgets everything up to now.
    func clear() {
        let now = Date()
        codecEntries = []
        forgotten = []
        clearedAt = now
        append(.clear(date: now))
        rebuild()
    }

    private func append(_ record: CommandHistory.LogRecord) {
        guard let logURL else { return }
        let line = CommandHistory.line(for: record)
        do {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if codecEntries.count > Self.limit {
                // Start the log over with the most recent entries.
                codecEntries.removeFirst(codecEntries.count - Self.limit * 3 / 4)
                var data = clearedAt.map { CommandHistory.line(for: .clear(date: $0)) } ?? Data()
                for command in forgotten { data += CommandHistory.line(for: .forget(command: command)) }
                for entry in codecEntries { data += CommandHistory.line(for: .entry(entry)) }
                try data.write(to: logURL, options: .atomic)
                return
            }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: logURL, options: .atomic)
            }
        } catch {
            Log.app.error("Couldn't save history: \(error.localizedDescription, privacy: .public)")
        }
    }
}
