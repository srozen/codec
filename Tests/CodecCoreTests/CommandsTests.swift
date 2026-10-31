import Testing
import Foundation
@testable import CodecCore

@Suite("IntegrationEvent")
struct IntegrationEventTests {
    @Test func parsesCommandStart() {
        #expect(IntegrationEvent(payload: "exec;make test") == .commandStarted("make test"))
    }

    @Test func keepsSemicolonsInsideTheCommand() {
        #expect(IntegrationEvent(payload: "exec;cd src; ls -la") == .commandStarted("cd src; ls -la"))
    }

    @Test func parsesAnEmptyCommand() {
        #expect(IntegrationEvent(payload: "exec;") == .commandStarted(""))
    }

    @Test func parsesCommandEnd() {
        #expect(IntegrationEvent(payload: "done;1;2.5") == .commandFinished(exitCode: 1, duration: 2.5))
        #expect(IntegrationEvent(payload: "done;0;0.0012") == .commandFinished(exitCode: 0, duration: 0.0012))
    }

    @Test(arguments: ["", "exec", "done", "done;1", "done;x;1", "done;1;y", "done;1;-3", "done;1;2;3", "ping;1"])
    func rejectsMalformedPayloads(payload: String) {
        #expect(IntegrationEvent(payload: payload) == nil)
    }
}

@Suite("CommandNames")
struct CommandNamesTests {
    @Test(arguments: [
        ("make test", "make"),
        ("/usr/bin/git status", "git"),
        ("sudo -E brew install jq", "brew"),
        ("FOO=1 BAR=2 npm run build", "npm"),
        ("time cargo build", "cargo"),
        ("env -i PATH=/bin ls", "ls"),
        ("  vim  ", "vim"),
    ])
    func extractsTheProgram(commandLine: String, program: String) {
        #expect(CommandNames.program(of: commandLine) == program)
    }

    @Test func fallsBackToTheTrimmedLine() {
        #expect(CommandNames.program(of: "sudo") == "sudo")
    }

    @Test(arguments: ["zsh", "-zsh", "bash", "fish", "login"])
    func recognizesShells(name: String) {
        #expect(CommandNames.isShell(name))
    }

    @Test(arguments: ["vim", "zshell", "-", "node"])
    func rejectsNonShells(name: String) {
        #expect(!CommandNames.isShell(name))
    }
}

@Suite("Formatting")
struct FormattingTests {
    @Test(arguments: [
        (0.0, "0 ms"), (0.3404, "340 ms"), (2.54, "2.5 s"), (59.9, "59.9 s"),
        (187, "3m 07s"), (3900, "1h 05m"), (-4, "0 ms"),
    ])
    func formatsDurations(seconds: Double, text: String) {
        #expect(Formatting.duration(seconds) == text)
    }

    @Test(arguments: [
        (0.0, "0", "B/s"), (512, "512", "B/s"), (1_200, "1.2", "KB/s"), (45_000, "45", "KB/s"),
        (3_400_000, "3.4", "MB/s"), (2_000_000_000, "2.0", "GB/s"), (-10, "0", "B/s"),
    ])
    func formatsByteRates(rate: Double, value: String, unit: String) {
        let formatted = Formatting.byteRate(rate)
        #expect(formatted.value == value)
        #expect(formatted.unit == unit)
    }

    @Test(arguments: [(999.4, "999", "B/s"), (999.7, "1.0", "KB/s"), (9_960, "10", "KB/s"), (999_600, "1.0", "MB/s")])
    func scalesBeforeRoundingReachesFourDigits(rate: Double, value: String, unit: String) {
        let formatted = Formatting.byteRate(rate)
        #expect(formatted.value == value)
        #expect(formatted.unit == unit)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func treatsNonFiniteRatesAsZero(rate: Double) {
        #expect(Formatting.byteRate(rate).value == "0")
    }

    /// Readouts have room for three digits; no rate may need more.
    @Test func byteRatesNeverNeedMoreThanThreeDigits() {
        var rate = 0.0
        while rate < 5e12 {
            let digits = Formatting.byteRate(rate).value.filter(\.isNumber).count
            #expect(digits <= 3, "\(rate) → \(Formatting.byteRate(rate))")
            rate = rate * 1.37 + 1
        }
    }

    @Test func formatsByteCounts() {
        #expect(!Formatting.bytes(16 * 1_073_741_824).isEmpty)
        #expect(Formatting.bytes(16 * 1_073_741_824).contains("16"))
    }
}

@Suite("FuzzyMatch")
struct FuzzyMatchTests {
    @Test func matchesSubsequencesCaseInsensitively() {
        #expect(FuzzyMatch.score("spr", in: "Split Pane Right") != nil)
        #expect(FuzzyMatch.score("SPLIT", in: "split pane right") != nil)
        #expect(FuzzyMatch.score("xyz", in: "Split Pane Right") == nil)
        #expect(FuzzyMatch.score("rs", in: "split") == nil)
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(FuzzyMatch.score("", in: "anything") == 0)
        #expect(FuzzyMatch.score("   ", in: "anything") == 0)
    }

    @Test func prefersWordStartsAndConsecutiveLetters() throws {
        let wordStarts = try #require(FuzzyMatch.score("nt", in: "New Tab"))
        let scattered = try #require(FuzzyMatch.score("nt", in: "Find Next"))
        #expect(wordStarts > scattered)
    }

    @Test func ranksBestFirstAndKeepsOrderForEmptyQueries() {
        let titles = ["Settings…", "Split Pane Right", "Split Pane Down", "New Tab"]
        #expect(FuzzyMatch.rank(titles, by: "", key: { $0 }) == titles)
        let ranked = FuzzyMatch.rank(titles, by: "down", key: { $0 })
        #expect(ranked == ["Split Pane Down"])
        #expect(FuzzyMatch.rank(titles, by: "split", key: { $0 }).count == 2)
    }
}
