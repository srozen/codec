import Testing
import Foundation
import AppKit
import CodecCore
@testable import CodecUI

/// The line above each command and the shade behind every other one, in a real pane running zsh.
@Suite("Command separators", .serialized, .timeLimit(.minutes(1)),
       .enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")))
@MainActor
struct CommandSeparatorTests {
    /// A pane in a window, its zsh kept from the user's own configuration.
    private func makeZshPane(_ env: TestEnvironment, promptedBy zshrc: String = "PS1='%# '\n") throws -> (Pane, NSWindow) {
        let config = env.directory.appendingPathComponent("zdotdir")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try zshrc.write(to: config.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        setenv("ZDOTDIR", config.path, 1)
        defer { unsetenv("ZDOTDIR") }
        let pane = env.makePane(host: FakeHost())
        let window = makeTestWindow(size: NSSize(width: 800, height: 300))
        window.contentView = pane.view
        pane.view.layoutSubtreeIfNeeded()
        return (pane, window)
    }

    private func run(_ command: String, in pane: Pane) async -> Bool {
        let count = pane.timeline.entries.count
        try? await Task.sleep(for: .milliseconds(200))
        pane.terminal.send(txt: command + "\r")
        return await waitUntil { pane.timeline.entries.count == count + 1 && pane.timeline.running == nil && pane.isAtCommandLine }
    }

    /// A visible row's frame in the separators' coordinates.
    private func frame(ofRow row: Int, in pane: Pane) throws -> NSRect {
        let grid = try #require(TerminalGrid(terminal: pane.terminal))
        return pane.view.commandSeparators.convert(grid.frame(row: row, columns: 0..<1), from: nil)
    }

    @Test func drawsALineAboveEachCommandAndShadesEveryOtherOne() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let (pane, window) = try makeZshPane(env)
        defer {
            pane.shutDown()
            window.close()
        }
        let separators = pane.view.commandSeparators
        #expect(await waitUntil { pane.isAtCommandLine })
        // The first prompt has nothing above it to be set apart from.
        #expect(separators.rules.isEmpty && separators.shades.isEmpty)

        #expect(await run("echo one", in: pane))
        #expect(await run("echo two", in: pane))
        // Rows: "% echo one", "one", "% echo two", "two", "% ".
        #expect(await waitUntil { separators.rules.count == 2 && separators.shades.count == 1 })
        let second = try frame(ofRow: 2, in: pane), waiting = try frame(ofRow: 4, in: pane)
        #expect(separators.rules.map(\.midY) == [second.maxY, waiting.maxY])
        #expect(separators.rules.allSatisfy { $0.height == 1 && $0.width == pane.terminal.frame.width })
        // The second command, from its line to the next, as wide as the pane.
        let shade = try #require(separators.shades.first)
        #expect(shade.frame.maxY == second.maxY && shade.frame.minY == waiting.maxY && shade.fade == 0)
        #expect(shade.frame.width == pane.view.bounds.width)
        // Both worked: nothing in the margin.
        #expect(separators.marks.isEmpty)

        // Each has its setting.
        env.preferences.commandSeparators = false
        pane.applyPreferences()
        #expect(separators.rules.isEmpty && separators.marks.isEmpty && separators.shades.count == 1)
        env.preferences.shadeAlternateCommands = false
        pane.applyPreferences()
        #expect(separators.rules.isEmpty && separators.shades.isEmpty)
        env.preferences.commandSeparators = true
        pane.applyPreferences()
        #expect(separators.rules.count == 2 && separators.shades.isEmpty)

        // Out of its window, as while another tab is selected, and back.
        window.contentView = NSView()
        pane.refreshCommandSeparators()
        #expect(separators.rules.isEmpty)
        window.contentView = pane.view
        window.layoutIfNeeded()
        #expect(await waitUntil { separators.rules.count == 2 })
    }

    /// Codec's prompt starts with a blank line: the line goes through the middle of it.
    @Test func drawsTheLineThroughAPromptsBlankFirstLine() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let (pane, window) = try makeZshPane(env, promptedBy: "PS1=$'\\n%# '\n")
        defer {
            pane.shutDown()
            window.close()
        }
        let separators = pane.view.commandSeparators
        #expect(await waitUntil { pane.isAtCommandLine })
        #expect(await run("echo one", in: pane))
        // Rows: "", "% echo one", "one", "", "% ".
        #expect(await waitUntil { separators.rules.count == 1 })
        let blank = try frame(ofRow: 3, in: pane)
        #expect(separators.rules.first?.midY == blank.midY)
        // The waiting prompt is the second command: shaded from its line, and fading out under its
        // last row, since it's not over.
        let last = try frame(ofRow: 4, in: pane)
        #expect(separators.shades == [.init(frame: NSRect(x: 0, y: last.minY - last.height, width: pane.view.bounds.width,
                                                          height: blank.midY - last.minY + last.height), fade: last.height)])
    }

    /// A bar in the margin beside a command that failed, and beside the one running; nothing beside one
    /// that worked.
    @Test func marksCommandsThatFailedOrAreRunning() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let (pane, window) = try makeZshPane(env)
        defer {
            pane.shutDown()
            window.close()
        }
        let separators = pane.view.commandSeparators
        #expect(await waitUntil { pane.isAtCommandLine })
        #expect(await run("false", in: pane))
        #expect(await waitUntil { separators.marks.map(\.kind) == [.failed] })
        // Beside its one row, between the pane's edge and the text.
        let failed = try #require(separators.marks.first?.frame), row = try frame(ofRow: 0, in: pane)
        #expect(failed.minX > 0 && failed.maxX < pane.terminal.frame.minX)
        #expect(failed.minY >= row.minY && failed.maxY <= row.maxY && failed.height == row.height - 6)
        pane.terminal.send(txt: "sleep 1\r")
        #expect(await waitUntil { separators.marks.map(\.kind) == [.failed, .running] })
        // It's the second command, and the newest: shaded, with no bottom edge yet.
        #expect(separators.shades.count == 1 && (separators.shades.first?.fade ?? 0) > 0)
        #expect(await waitUntil { separators.marks.map(\.kind) == [.failed] && separators.shades.map(\.fade) == [0] })
    }

    /// `clear` leaves the commands that were on screen nowhere: nothing is drawn where they were.
    @Test func forgetsCommandsWhenTheScreenIsCleared() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let (pane, window) = try makeZshPane(env)
        defer {
            pane.shutDown()
            window.close()
        }
        let separators = pane.view.commandSeparators
        #expect(await waitUntil { pane.isAtCommandLine })
        #expect(await run("echo one", in: pane))
        #expect(await run("echo two", in: pane))
        #expect(await waitUntil { separators.rules.count == 2 })
        #expect(await run("clear", in: pane))
        #expect(await waitUntil { separators.rules.isEmpty && separators.shades.isEmpty })
        #expect(pane.blocks.blocks.isEmpty)
        // Empty prompts take up the rows the commands were on: the only line is above the one waiting.
        pane.terminal.send(txt: "\r\r\r\r\r")
        #expect(await waitUntil { pane.terminal.visibleRowsText(0..<8).filter { $0.hasPrefix("%") }.count == 6 })
        let waiting = try frame(ofRow: 5, in: pane)
        #expect(await waitUntil { separators.rules.map(\.midY) == [waiting.maxY] })
        #expect(separators.shades.isEmpty)
        // Counting starts over: the first command after the clear isn't shaded, the prompt after it is.
        #expect(await run("echo three", in: pane))
        #expect(await waitUntil { separators.rules.count == 2 && separators.shades.count == 1 })
        #expect(separators.shades.first?.frame.maxY == (try frame(ofRow: 7, in: pane)).maxY)
    }

    /// A full-screen program's screen isn't the commands': nothing is drawn over it, and all of it is
    /// back when the program leaves.
    @Test func hidesWhileAFullScreenProgramHasTheScreen() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let (pane, window) = try makeZshPane(env)
        defer {
            pane.shutDown()
            window.close()
        }
        let separators = pane.view.commandSeparators
        #expect(await waitUntil { pane.isAtCommandLine })
        #expect(await run("echo one", in: pane))
        #expect(await waitUntil { separators.rules.count == 1 })
        pane.terminal.send(txt: "printf '\\e[?1049h'; sleep 1; printf '\\e[?1049l'\r")
        #expect(await waitUntil { pane.terminal.terminalInputStateSnapshot()?.isAlternateBuffer == true })
        #expect(await waitUntil { separators.rules.isEmpty && separators.shades.isEmpty })
        #expect(await waitUntil { pane.isAtCommandLine && separators.rules.count == 2 && separators.shades.count == 1 })
    }

    /// A narrower terminal rewraps its lines, and the commands are found again where they went.
    @Test func followsCommandsWhenTheTerminalIsResized() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let (pane, window) = try makeZshPane(env)
        defer {
            pane.shutDown()
            window.close()
        }
        let separators = pane.view.commandSeparators
        #expect(await waitUntil { pane.isAtCommandLine })
        #expect(await run("echo \(String(repeating: "wide ", count: 20))", in: pane))
        #expect(await run("echo two", in: pane))
        #expect(await waitUntil { separators.rules.count == 2 })

        window.setContentSize(NSSize(width: 420, height: 300))
        pane.view.layoutSubtreeIfNeeded()
        func row(startingWith text: String) -> Int? { pane.terminal.visibleRowsText(0..<12).firstIndex { $0.hasPrefix(text) } }
        #expect(await waitUntil { (row(startingWith: "% echo two") ?? 0) > 2 })
        let second = try #require(row(startingWith: "% echo two"))
        #expect(await waitUntil {
            separators.rules.count == 2 && separators.rules.first?.midY == (try? frame(ofRow: second, in: pane))?.maxY
        })
    }
}
