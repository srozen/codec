import Testing
import Foundation
import AppKit
import SwiftTerm
import CodecCore
@testable import CodecUI

/// Folding a command's output under its command line, in a real pane running zsh.
@Suite("Folding output", .serialized, .timeLimit(.minutes(2)),
       .enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh")))
@MainActor
struct FoldTests {
    /// A pane in a window, its zsh kept from the user's own configuration.
    private func makeZshPane(_ env: TestEnvironment, promptedBy zshrc: String = "PS1='%# '\n",
                             restoring contents: SavedPaneContents? = nil) throws -> (Pane, NSWindow) {
        let config = env.directory.appendingPathComponent("zdotdir")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try zshrc.write(to: config.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        setenv("ZDOTDIR", config.path, 1)
        defer { unsetenv("ZDOTDIR") }
        let pane = Pane(directory: env.directory.path, environment: env.environment, restoring: contents)
        pane.host = FakeHost()
        // Nowhere near the pane, wherever the mouse really is.
        pane.pointerLocation = { nil }
        let window = makeTestWindow(size: NSSize(width: 800, height: 300))
        window.contentView = pane.view
        pane.view.layoutSubtreeIfNeeded()
        return (pane, window)
    }

    private func run(_ command: String, in pane: Pane) async -> Bool {
        let count = pane.timeline.entries.count
        try? await Task.sleep(for: .milliseconds(200))
        pane.terminal.send(txt: command + "\r")
        return await waitUntil {
            pane.timeline.entries.count == count + 1 && pane.timeline.running == nil && pane.canFoldNow
                && pane.timeline.entries.last?.output != nil
        }
    }

    /// Every line in the scrollback down to the cursor, without the blank space at their ends.
    private func lines(of pane: Pane) -> [String] {
        guard let snapshot = pane.terminal.terminalContentSnapshot(region: .history(maximumScrollbackRows: 10_000)) else { return [] }
        return snapshot.rows.filter { $0.absoluteRow <= snapshot.cursorRow }
            .map { $0.text.replacingOccurrences(of: "[\\s\0]+$", with: "", options: .regularExpression) }
    }

    @Test func foldsOutputUnderItsCommandLineAndPutsItBack() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let (pane, window) = try makeZshPane(env)
        defer {
            pane.shutDown()
            window.close()
        }
        #expect(await waitUntil { pane.isAtCommandLine })
        #expect(await run("echo first", in: pane))
        #expect(await run("seq 1 60", in: pane))
        #expect(await run("echo last", in: pane))
        let before = lines(of: pane)
        let seq = pane.timeline.entries[1]
        #expect(pane.canFold(seq))
        // A single line isn't worth a row saying so.
        #expect(!pane.canFold(pane.timeline.entries[0]))

        #expect(pane.fold(seq))
        #expect(lines(of: pane) == ["% echo first", "first", "% seq 1 60", "", "% echo last", "last", "%"])
        let folded = try #require(pane.timeline.entries[1].fold)
        #expect(folded.lineCount == 60)
        #expect(folded.text == (1...60).map(String.init).joined(separator: "\n"))
        #expect(!pane.canFold(pane.timeline.entries[1]))
        // Every command is found where it is now, and the row is drawn over.
        #expect(pane.timeline.entries.map(\.block?.output) == [1, 3, 5])
        let row = try #require(pane.view.folds.rows.first)
        #expect(pane.view.folds.rows.count == 1)
        #expect(row.summary.text.hasPrefix("60 lines · "))
        #expect(row.summary.text.hasSuffix(" · ✓ 60"))
        let grid = try #require(TerminalGrid(terminal: pane.terminal))
        #expect(row.frame == pane.view.folds.convert(grid.frame(row: 3 - grid.viewportTop, columns: 0..<grid.columns), from: nil))
        // Its output is still all there to copy and to read.
        #expect(pane.output(of: seq)?.hasSuffix("59\n60") == true)
        NSPasteboard.general.clearContents()
        pane.copyOutput(3..<4)
        #expect(NSPasteboard.general.string(forType: .string) == folded.text)

        // The shell carries on as if nothing happened.
        #expect(await run("echo after", in: pane))
        #expect(lines(of: pane).suffix(3) == ["% echo after", "after", "%"])
        #expect(pane.timeline.entries.map(\.block?.output) == [1, 3, 5, 7])

        #expect(pane.unfold(pane.timeline.entries[1]))
        #expect(pane.timeline.entries[1].fold == nil)
        #expect(lines(of: pane) == Array(before.dropLast()) + ["% echo after", "after", "%"])
        #expect(pane.view.folds.rows.isEmpty)
        #expect(await run("echo again", in: pane))
        #expect(pane.timeline.entries.allSatisfy { $0.block != nil })
    }

    @Test func foldsFromTheKeyboardTheRowAndTheButton() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        // A prompt of two lines, and something typed at it, come through a fold as they were.
        let (pane, window) = try makeZshPane(env, promptedBy: "PS1=$'%F{green}here%f\\n%# '\n")
        defer {
            pane.shutDown()
            window.close()
        }
        #expect(await waitUntil { pane.isAtCommandLine })
        #expect(await run("seq 1 8", in: pane))
        #expect(await run("seq 11 18", in: pane))
        #expect(await run("seq 21 28", in: pane))
        pane.terminal.send(txt: "echo typ")
        #expect(await waitUntil { lines(of: pane).last == "% echo typ" })

        // Every command but the last, which is likely still being read.
        #expect(pane.foldAllOutput())
        #expect(pane.timeline.entries.map { $0.fold != nil } == [true, true, false])
        #expect(lines(of: pane).suffix(2) == ["here", "% echo typ"])
        #expect(pane.view.folds.rows.count == 2)
        // The newest with output to fold, then nothing left.
        #expect(pane.foldOutput())
        #expect(pane.timeline.entries.allSatisfy { $0.fold != nil })
        #expect(!pane.foldOutput())
        #expect(lines(of: pane) == ["here", "% seq 1 8", "", "here", "% seq 11 18", "", "here", "% seq 21 28", "", "here", "% echo typ"])
        // The one folded last comes back first.
        #expect(pane.unfoldOutput())
        #expect(pane.timeline.entries.map { $0.fold != nil } == [true, true, false])

        // The pointer on a folded row lights it up; a click there unfolds (below).
        let grid = try #require(TerminalGrid(terminal: pane.terminal))
        let firstFold = try #require(pane.timeline.entries[0].block?.output)
        pane.pointerLocation = { grid.center(row: firstFold - grid.viewportTop, column: 3) }
        pane.refreshFolds()
        #expect(pane.view.folds.rows.map(\.isHovered) == [true, false])
        #expect(pane.view.folds.button == nil)
        // Anywhere in a command, its output too, brings up the button at the right of its command line.
        let third = try #require(pane.timeline.entries[2].block)
        pane.pointerLocation = { grid.center(row: third.output + 4 - grid.viewportTop, column: 3) }
        pane.refreshFolds()
        let button = try #require(pane.view.folds.button)
        #expect(button.title == "Fold 8 lines" && !button.isHovered)
        let commandLine = pane.view.folds.convert(grid.frame(row: third.output - 1 - grid.viewportTop, columns: 0..<grid.columns), from: nil)
        #expect(commandLine.contains(button.frame) && button.frame.maxX > commandLine.maxX - 8)
        #expect(pane.view.folds.hitTest(pane.view.convert(NSPoint(x: button.frame.midX, y: button.frame.midY), from: pane.view.folds)) === pane.view.folds)
        pane.foldAtButton()
        #expect(pane.timeline.entries.allSatisfy { $0.fold != nil })
        pane.refreshFolds()
        #expect(pane.view.folds.button == nil)
        #expect(pane.unfold(pane.timeline.entries[0]))
        #expect(pane.foldOutput())
        #expect(pane.unfold(pane.timeline.entries[2]))
        #expect(pane.timeline.entries.map { $0.fold != nil } == [true, true, false])

        // A click on a folded row unfolds it.
        let second = try #require(pane.timeline.entries[1].block?.output)
        let point = try #require(TerminalGrid(terminal: pane.terminal)).center(row: second, column: 10)
        #expect(pane.foldedEntry(at: point)?.id == pane.timeline.entries[1].id)
        pane.pointerLocation = { nil }
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                   clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: 0))
        pane.terminal.mouseDown(with: down)
        pane.terminal.mouseUp(with: up)
        #expect(pane.timeline.entries.map { $0.fold != nil } == [true, false, false])
        #expect(!pane.terminal.selectionActive)

        // What was typed is still on the line, and runs.
        pane.terminal.send(txt: "ed\r")
        #expect(await waitUntil { pane.timeline.entries.last?.command == "echo typed" && pane.canFoldNow })
        #expect(lines(of: pane).suffix(4) == ["% echo typed", "typed", "here", "%"])
        // The prompts are marked for ⌘↑ as the shell marked them.
        pane.terminal.scrollTo(row: Int.max)
        #expect(pane.terminal.previousSemanticPromptRow() != nil)
    }

    @Test func theContextMenuFoldsTheCommandUnderIt() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let (pane, window) = try makeZshPane(env)
        defer {
            pane.shutDown()
            window.close()
        }
        #expect(await waitUntil { pane.isAtCommandLine })
        #expect(pane.contextMenu().item(titled: "Fold Output")?.isEnabled == false)
        #expect(await run("seq 1 5", in: pane))
        let grid = try #require(TerminalGrid(terminal: pane.terminal))
        let output = grid.center(row: 2, column: 0)
        let menu = pane.contextMenu(at: output)
        #expect(menu.item(titled: "Fold Output")?.isEnabled == true)
        menu.perform("Fold Output")
        #expect(pane.timeline.entries[0].fold != nil)
        #expect(pane.contextMenu(at: grid.center(row: 1, column: 0)).item(titled: "Fold Output") == nil)
        pane.contextMenu(at: grid.center(row: 1, column: 0)).perform("Unfold Output")
        #expect(pane.timeline.entries[0].fold == nil)

        // Not while a program runs: what it prints meanwhile would be lost.
        pane.terminal.send(txt: "sleep 30\r")
        #expect(await waitUntil { pane.timeline.running != nil })
        #expect(!pane.canFoldNow)
        #expect(pane.contextMenu(at: output).item(titled: "Fold Output")?.isEnabled == false)
        #expect(!pane.foldOutput())
        #expect(pane.timeline.entries[0].fold == nil)
    }

    @Test func findUnfoldsWhatHoldsAMatch() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let (pane, window) = try makeZshPane(env)
        defer {
            pane.shutDown()
            window.close()
        }
        #expect(await waitUntil { pane.isAtCommandLine })
        #expect(await run("seq 100 140", in: pane))
        #expect(await run("seq 200 240", in: pane))
        #expect(await run("echo done", in: pane))
        #expect(pane.foldAllOutput())
        #expect(pane.timeline.entries.map { $0.fold != nil } == [true, true, false])

        pane.view.finder.open(query: "217")
        #expect(pane.timeline.entries.map { $0.fold != nil } == [true, false, false])
        #expect(pane.view.finder.matches.count == 1)
        #expect(lines(of: pane).contains("217"))
        // Going to a command from the Commands sidebar with a filter does the same.
        let first = pane.timeline.entries[0]
        let expression = try #require(TextSearch.expression(for: "13\\d", options: FindOptions(regex: true)))
        let row = try #require(pane.reveal(first, matching: expression))
        #expect(pane.timeline.entries[0].fold == nil)
        #expect(lines(of: pane)[row] == "130")
    }

    @Test func foldsLongOutputOnceTheNextCommandHasRun() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        env.preferences.foldLongOutput = true
        env.preferences.foldLongOutputLines = 20
        let (pane, window) = try makeZshPane(env)
        defer {
            pane.shutDown()
            window.close()
        }
        #expect(await waitUntil { pane.isAtCommandLine })
        #expect(await run("seq 1 30", in: pane))
        #expect(await run("seq 1 10", in: pane))
        // The long one folds now that another has run; the short one never does.
        #expect(await waitUntil { pane.timeline.entries[0].fold != nil })
        #expect(await run("echo third", in: pane))
        try await Task.sleep(for: .milliseconds(700))
        #expect(pane.timeline.entries.map { $0.fold != nil } == [true, false, false])
        // Unfolded by hand, it stays that way.
        #expect(pane.unfold(pane.timeline.entries[0]))
        #expect(await run("echo fourth", in: pane))
        try await Task.sleep(for: .milliseconds(700))
        #expect(pane.timeline.entries.allSatisfy { $0.fold == nil })
    }

    @Test func foldsComeBackWithThePanesContents() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true)
        defer { env.tearDown() }
        let (pane, window) = try makeZshPane(env)
        #expect(await waitUntil { pane.isAtCommandLine })
        #expect(await run("echo first", in: pane))
        #expect(await run("seq 1 40", in: pane))
        // The newest command's, so the row standing in for it is the last thing above the prompt.
        #expect(pane.foldOutput())
        let contents = try #require(pane.savedContents())
        pane.shutDown()
        window.close()
        #expect(contents.timeline.entries.map { $0.fold != nil } == [false, true])
        #expect(contents.transcript.hasSuffix("\r\n\r\n") && !contents.transcript.contains("39"))

        let (restored, other) = try makeZshPane(env, restoring: contents)
        defer {
            restored.shutDown()
            other.close()
        }
        #expect(await waitUntil { restored.canFoldNow })
        #expect(await run("echo after", in: restored))
        restored.refreshFolds()
        #expect(restored.view.folds.rows.map(\.summary.lines) == ["40 lines"])
        let folded = try #require(restored.timeline.entries.first { $0.fold != nil })
        #expect(restored.unfold(folded))
        let shown = lines(of: restored)
        #expect(shown.contains("40") && shown.contains("1"))
        let index = try #require(shown.firstIndex(of: "% seq 1 40"))
        #expect(Array(shown[(index + 1)...(index + 40)]) == (1...40).map(String.init))
    }
}
