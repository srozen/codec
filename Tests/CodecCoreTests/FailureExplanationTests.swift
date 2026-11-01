import Testing
import Foundation
@testable import CodecCore

@Suite("Failure explanation")
struct FailureExplanationTests {
    private func entry(_ command: String, exitCode: Int32?) -> TimelineEntry {
        var entry = TimelineEntry(id: 1, command: command, directory: NSHomeDirectory() + "/project", started: Date(), block: nil)
        entry.exitCode = exitCode
        return entry
    }

    @Test func reportsOnlyCommandsThatFailedWithAnExitStatus() throws {
        #expect(FailureReport(entry: entry("true", exitCode: 0), output: nil) == nil)
        #expect(FailureReport(entry: entry("sleep 9", exitCode: nil), output: nil) == nil)
        // Ended without a report: there's no exit status to explain.
        #expect(FailureReport(entry: entry("make", exitCode: -1), output: "x") == nil)

        let report = try #require(FailureReport(entry: entry("ls nope", exitCode: 1),
                                                output: "ls: nope: No such file or directory\n\n"))
        #expect(report.directory == "~/project")
        #expect(report.prompt == """
            Command: ls nope
            Folder: ~/project
            Exit status: 1
            Output:
            ls: nope: No such file or directory
            """)
        #expect(FailureReport(entry: entry("false", exitCode: 1), output: nil)?.prompt.hasSuffix("Output:\n(nothing)") == true)
    }

    @Test func keepsShortOutputWhole() {
        #expect(FailureReport.excerpt("one\ntwo\n\n", budget: 100) == "one\ntwo")
    }

    @Test func keepsTheEndAndEarlierErrorsOfLongOutput() {
        let lines = ["Compiling A", "src/a.swift:3: error: cannot find 'x' in scope"]
            + (1...200).map { "Compiling file \($0)" } + ["Build failed"]
        let excerpt = FailureReport.excerpt(lines.joined(separator: "\n"), budget: 1_000)
        #expect(excerpt.count <= 1_000)
        let kept = excerpt.split(separator: "\n").map(String.init)
        #expect(kept.first == "src/a.swift:3: error: cannot find 'x' in scope")
        #expect(kept[1] == "…")
        #expect(kept.last == "Build failed")
        #expect(!kept.contains("Compiling A"))
        #expect(!kept.contains("Compiling file 1"))
    }

    @Test func clipsVeryLongLines() {
        let excerpt = FailureReport.excerpt(String(repeating: "x", count: 5_000) + "\nfailed", budget: 600)
        #expect(excerpt.count <= 600)
        #expect(excerpt.hasSuffix("…\nfailed"))
    }

    @Test func spotsLinesThatLookLikeErrors() {
        #expect(FailureReport.looksLikeAnError("zsh: command not found: gti"))
        #expect(FailureReport.looksLikeAnError("FATAL: role \"x\" does not exist"))
        #expect(FailureReport.looksLikeAnError("Traceback (most recent call last):"))
        #expect(!FailureReport.looksLikeAnError("Compiling Codec"))
    }
}
