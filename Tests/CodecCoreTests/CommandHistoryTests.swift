import Testing
import Foundation
@testable import CodecCore

@Suite("CommandHistory")
struct CommandHistoryTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(_ command: String, _ minutes: Double, in directory: String? = "/repo", exit: Int32? = 0,
                       source: HistoryEntry.Source = .codec) -> HistoryEntry {
        HistoryEntry(command: command, date: base.addingTimeInterval(minutes * 60), directory: source == .codec ? directory : nil,
                     exitCode: source == .codec ? exit : nil, duration: source == .codec ? 1 : nil, source: source)
    }

    private var sample: CommandHistory {
        CommandHistory(entries: [
            entry("git status", 0),
            entry("make test", 1, exit: 2),
            entry("git commit -m 'Fix'", 2),
            entry("git status", 3, in: "/other"),
            entry("Git log", 4),
            entry("npm run dev", 5, in: "/web"),
            entry("cd ~/Development", 6, in: "/"),
        ])
    }

    @Test func listsTheMostRecentFirstMergingRepeats() {
        let items = sample.items(matching: "")
        #expect(items.map(\.command) == ["cd ~/Development", "npm run dev", "Git log", "git status", "git commit -m 'Fix'", "make test"])
        let status = items.first { $0.command == "git status" }
        #expect(status?.count == 2)
        #expect(status?.latest.directory == "/other")
    }

    @Test func ranksPrefixThenCaseThenContainsThenFuzzy() {
        let items = sample.items(matching: "git")
        // Exact-case prefixes (most recent first), then a case-insensitive prefix.
        #expect(items.map(\.command) == ["git status", "git commit -m 'Fix'", "Git log"])
        #expect(items.first?.match == 0..<3)

        #expect(sample.items(matching: "dev").map(\.command) == ["cd ~/Development", "npm run dev"])
        #expect(sample.items(matching: "dev").first?.match == 5..<8)
        // Fuzzy, last.
        #expect(sample.items(matching: "gcm").map(\.command) == ["git commit -m 'Fix'"])
        #expect(sample.items(matching: "zzz").isEmpty)
    }

    @Test func prefersCommandsFromTheCurrentDirectory() {
        let history = CommandHistory(entries: [entry("ls -la", 0, in: "/here"), entry("ls", 1, in: "/there")])
        #expect(history.items(matching: "ls", directory: "/here").map(\.command) == ["ls -la", "ls"])
        #expect(history.items(matching: "ls").map(\.command) == ["ls", "ls -la"])
    }

    @Test func filters() {
        #expect(sample.items(matching: "", filter: .failed).map(\.command) == ["make test"])
        #expect(sample.items(matching: "", filter: .directory("/other")).map(\.command) == ["git status"])
        #expect(sample.items(matching: "", filter: .directory("/repo")).map(\.command).contains("git status"))
        #expect(sample.items(matching: "", limit: 2).count == 2)
    }

    @Test func keepsTimeOrderWhenRunsFinishOutOfOrder() {
        var history = CommandHistory()
        history.append(entry("second", 2))
        history.append(entry("first", 1))
        history.append(entry("third", 3))
        history.append(entry("also second", 2))
        #expect(history.entries.map(\.command) == ["first", "second", "also second", "third"])
        #expect(history.items(matching: "").first?.command == "third")
    }

    @Test func skipsBlankAndSpaceHiddenCommands() {
        var history = CommandHistory()
        history.append(entry("  ", 0))
        history.append(entry(" secret --token", 0))
        history.append(entry("ls", 1))
        #expect(history.entries.map(\.command) == ["ls"])
    }

    @Test func shellEntriesBorrowCodecsDetails() {
        var history = CommandHistory(entries: [entry("make", 0, in: "/repo", exit: 1)])
        history.merge([entry("make", 5, source: .shell)])
        let item = history.items(matching: "").first
        #expect(item?.count == 2)
        #expect(item?.latest.date == base.addingTimeInterval(300))
        #expect(item?.latest.directory == "/repo")
        #expect(item?.failed == true)
    }

    @Test func replaysTheLog() {
        var log = Data()
        for record: CommandHistory.LogRecord in [
            .entry(entry("one", 0)), .entry(entry("two", 1)), .forget(command: "one"), .entry(entry("three", 2)),
            .clear(date: base.addingTimeInterval(90)), .entry(entry("four", 3)),
        ] {
            log += CommandHistory.line(for: record)
        }
        log += Data("{not json\n".utf8)
        let replayed = CommandHistory.replay(log)
        #expect(replayed.entries.map(\.command) == ["three", "four"])
        #expect(replayed.clearedAt == base.addingTimeInterval(90))
        #expect(replayed.forgotten.isEmpty)
        let forgetting = CommandHistory.replay(CommandHistory.line(for: .forget(command: "x")))
        #expect(forgetting.forgotten == ["x"])
    }

    @Test func readsZshHistory() {
        let extended = ": 1700000000:0;git status\n: 1700000060:3;echo one\\\ntwo\n: 1700000120:0;ls\n"
        let entries = CommandHistory.parseZshHistory(Data(extended.utf8))
        #expect(entries.map(\.command) == ["git status", "echo one\ntwo", "ls"])
        #expect(entries[1].date == Date(timeIntervalSince1970: 1_700_000_060))
        #expect(entries.allSatisfy { $0.source == .shell })

        let modified = Date(timeIntervalSince1970: 1_800_000_000)
        let plain = CommandHistory.parseZshHistory(Data("make\nmake test\n".utf8), modified: modified)
        #expect(plain.map(\.command) == ["make", "make test"])
        #expect(plain[0].date < plain[1].date)
        #expect(plain[1].date < modified)
    }

    @Test func undoesZshsMetafication() {
        // "é" is C3 A9; zsh writes A9 as 83 89.
        let data = Data([0x65, 0x63, 0x68, 0x6F, 0x20, 0xC3, 0x83, 0x89])
        #expect(CommandHistory.parseZshHistory(data).first?.command == "echo é")
    }

    @Test func relativeTimes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_700_000_000)  // Tuesday 14 Nov 2023, 22:13 UTC
        #expect(Formatting.relativeTime(now.addingTimeInterval(-20), now: now, calendar: calendar) == "now")
        #expect(Formatting.relativeTime(now.addingTimeInterval(-300), now: now, calendar: calendar) == "5m")
        #expect(Formatting.relativeTime(now.addingTimeInterval(-3 * 3600), now: now, calendar: calendar) == "3h")
        #expect(Formatting.relativeTime(now.addingTimeInterval(-86_400), now: now, calendar: calendar) == "Yesterday")
        #expect(Formatting.relativeTime(now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar) == "Sat")
        #expect(Formatting.relativeTime(now.addingTimeInterval(-30 * 86_400), now: now, calendar: calendar) == "Oct 15")
        #expect(Formatting.relativeTime(now.addingTimeInterval(-400 * 86_400), now: now, calendar: calendar) == "Oct 10, 2022")
    }
}
