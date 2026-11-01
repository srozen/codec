import Testing
import AppKit
import CodecCore
@testable import CodecUI

/// How long commands usually take, shown while they run and once they're done.
@Suite("Usual duration in the window", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct UsualDurationUITests {
    private func entry(_ command: String, started: Date, usual: TimeInterval?, duration: TimeInterval? = nil,
                       exitCode: Int32? = nil) -> TimelineEntry {
        var entry = TimelineEntry(id: 1, command: command, directory: "/p", started: started, block: nil)
        entry.usualDuration = usual
        entry.duration = duration
        entry.exitCode = exitCode
        return entry
    }

    @Test func theSidebarShowsProgressThenHowItCompared() throws {
        let cell = TimelineCell()
        let theme = CodecTheme.codec
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        cell.show(entry("make test", started: Date().addingTimeInterval(-42), usual: 96), query: "", inScrollback: true,
                  theme: theme, codeFont: font)
        #expect(cell.shown.detail == "54 s left · usually 1m 36s")
        #expect(abs((cell.shown.progress ?? 0) - 42.0 / 96) < 0.02)

        cell.show(entry("make test", started: Date().addingTimeInterval(-108), usual: 96), query: "", inScrollback: true,
                  theme: theme, codeFont: font)
        #expect(cell.shown.detail == "12 s over its usual 1m 36s")
        #expect(cell.shown.progress == 1 && cell.shown.durationColor == theme.warning)

        // Done: slower ones say by how much; the rest look as they always did.
        cell.show(entry("npm run lint", started: Date(), usual: 80, duration: 130, exitCode: 0), query: "", inScrollback: true,
                  theme: theme, codeFont: font)
        #expect(cell.shown.duration == "2m 10s · 1.6×" && cell.shown.durationColor == theme.warning && cell.shown.progress == nil)
        #expect(cell.accessibilityLabel()?.contains("1.6× its usual 1m 20s") == true)
        cell.show(entry("swift build", started: Date(), usual: 48, duration: 47, exitCode: 0), query: "", inScrollback: true,
                  theme: theme, codeFont: font)
        #expect(cell.shown.duration == "47.0 s" && cell.shown.durationColor == .secondaryLabelColor)
        // A failed run isn't compared: it ended early.
        cell.show(entry("swift build", started: Date(), usual: 48, duration: 300, exitCode: 1), query: "", inScrollback: true,
                  theme: theme, codeFont: font)
        #expect(cell.shown.duration == "5m 00s")
        // Without a usual time, a running command reads as before.
        cell.show(entry("make", started: Date(), usual: nil), query: "", inScrollback: true, theme: theme, codeFont: font)
        #expect(cell.shown.detail == "Running…" && cell.shown.progress == nil)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")))
    func aCommandThatRanBeforeGetsItsUsualTime() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let config = env.directory.appendingPathComponent("zdotdir")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "PS1='%# '\n".write(to: config.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        setenv("ZDOTDIR", config.path, 1)
        defer { unsetenv("ZDOTDIR") }
        for (index, duration) in [5.0, 7, 6].enumerated() {
            env.environment.history.record(HistoryEntry(command: "echo usual-run", date: Date(timeIntervalSinceNow: Double(index - 10)),
                                                        directory: env.directory.path, exitCode: 0, duration: duration))
        }
        let pane = env.makePane(host: FakeHost())
        let window = makeTestWindow(size: NSSize(width: 700, height: 300))
        window.contentView = pane.view
        defer {
            pane.shutDown()
            window.close()
        }
        #expect(await waitUntil { pane.isAtCommandLine })
        try await Task.sleep(for: .milliseconds(200))
        pane.terminal.send(txt: "echo usual-run\r")
        #expect(await waitUntil { pane.timeline.entries.last?.exitCode != nil })
        #expect(pane.timeline.entries.last?.usualDuration == 6)
        #expect(pane.usualDuration(of: "echo never-ran") == nil)

        // Turned off, nothing's worked out.
        env.preferences.showUsualDuration = false
        #expect(pane.usualDuration(of: "echo usual-run") == nil)
    }
}
