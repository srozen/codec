import Testing
import Foundation
@testable import CodecCore

@Suite("Usual duration")
struct UsualDurationTests {
    private func runs(_ command: String, _ durations: [TimeInterval], in directory: String = "/p", status: Int32 = 0,
                      source: HistoryEntry.Source = .codec) -> [HistoryEntry] {
        durations.enumerated().map { index, duration in
            HistoryEntry(command: command, date: Date(timeIntervalSince1970: Double(index)), directory: directory,
                         exitCode: status, duration: duration, source: source)
        }
    }

    @Test func isTheMedianOfTheRecentCleanRuns() {
        let history = runs("make test", [91, 98, 96])
        #expect(UsualDuration.of("make test", in: "/p", history: history) == 96)
        #expect(UsualDuration.of("  make test \n", in: "/p", history: history) == 96)
        // Even counts take the middle two.
        #expect(UsualDuration.of("make test", in: "/p", history: runs("make test", [90, 100, 94, 96])) == 95)
        // Only the last ten count: a build that got faster shows it.
        let faster = runs("make", Array(repeating: 200, count: 15) + Array(repeating: 50, count: 10))
        #expect(UsualDuration.of("make", in: "/p", history: faster) == 50)
    }

    @Test func needsEnoughCleanRuns() {
        #expect(UsualDuration.of("make test", in: "/p", history: runs("make test", [91, 98])) == nil)
        // Failed and interrupted runs end early, so they don't count.
        let mixed = runs("make test", [91, 98]) + runs("make test", [4], status: 2) + runs("make test", [12], status: 130)
        #expect(UsualDuration.of("make test", in: "/p", history: mixed) == nil)
        // Nor do commands from the shell's own history, which has no durations to speak of.
        #expect(UsualDuration.of("make test", in: "/p", history: runs("make test", [90, 91, 92], source: .shell)) == nil)
        // Other commands aren't this one.
        #expect(UsualDuration.of("make test JOBS=8", in: "/p", history: runs("make test", [91, 98, 96])) == nil)
    }

    @Test func prefersRunsInTheSameFolder() {
        let history = runs("make test", [10, 11, 12], in: "/other") + runs("make test", [90, 95, 96], in: "/p")
        #expect(UsualDuration.of("make test", in: "/p", history: history) == 95)
        #expect(UsualDuration.of("make test", in: "/other", history: history) == 11)
        // Too few here: runs anywhere count.
        let elsewhere = runs("make test", [40, 41, 42], in: "/other") + runs("make test", [90], in: "/p")
        #expect(UsualDuration.of("make test", in: "/p", history: elsewhere) == 41.5)
    }

    @Test func leavesOutQuickAndIrregularCommands() {
        #expect(UsualDuration.of("ls", in: "/p", history: runs("ls", [0.1, 0.2, 0.1])) == nil)
        // git push: 1 s or 30 s, depending.
        #expect(UsualDuration.of("git push", in: "/p", history: runs("git push", [3, 30, 4, 28, 5, 31])) == nil)
        // One run that sat on a password prompt doesn't spoil it.
        #expect(UsualDuration.of("make", in: "/p", history: runs("make", [60, 62, 61, 63, 400])) == 62)
    }

    @Test func comparesARunWithTheUsualTime() {
        #expect(UsualDuration.Comparison(duration: 91, usual: 96) == .asUsual)
        #expect(UsualDuration.Comparison(duration: 120, usual: 96) == .asUsual)
        #expect(UsualDuration.Comparison(duration: 130, usual: 80) == .slower(1.625))
        #expect(UsualDuration.Comparison(duration: 130, usual: 80).multiplier == "1.6×")
        #expect(UsualDuration.Comparison(duration: 30, usual: 80) == .faster(0.375))
        #expect(UsualDuration.Comparison(duration: 1200, usual: 60).multiplier == "20×")
    }

    @Test func formatsTickingTimes() {
        #expect(Formatting.seconds(8.4) == "8 s")
        #expect(Formatting.seconds(96) == "1m 36s")
        #expect(Formatting.seconds(3900) == "1h 05m")
        #expect(Formatting.seconds(-2) == "0 s")
    }
}
