import Testing
import AppKit
import CodecCore
import SwiftTerm
@testable import CodecUI

@Suite("Find in the terminal", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct FindTests {
    private func row(_ number: Int, _ text: String, wrapped: Bool = false) -> TerminalContentRowSnapshot {
        TerminalContentRowSnapshot(absoluteRow: number, cells: text.map {
            TerminalCellSnapshot(text: String($0), width: 1, attribute: .empty)
        }, isWrapped: wrapped)
    }

    @Test func findsMatchesAcrossSoftWrappedRows() throws {
        let expression = try #require(TextSearch.expression(for: "error", options: FindOptions()))
        let matches = TerminalFinder.matches(of: expression, in: [
            row(10, "an error and anoth"),
            row(11, "er err", wrapped: true),
            row(12, "or here"),
        ])
        typealias Run = TerminalFinder.Match.Run
        #expect(matches.map(\.runs) == [[Run(row: 10, columns: 3..<8)]])
        let split = try #require(TextSearch.expression(for: "another", options: FindOptions()))
        #expect(TerminalFinder.matches(of: split, in: [row(10, "an error and anoth"), row(11, "er", wrapped: true)])
            .map(\.runs) == [[Run(row: 10, columns: 13..<18), Run(row: 11, columns: 0..<2)]])
    }

    @Test func wideCharactersTakeTwoColumns() throws {
        let cells = [TerminalCellSnapshot(text: "界", width: 2, attribute: .empty),
                     TerminalCellSnapshot(text: "", width: 0, attribute: .empty)]
            + "ok".map { TerminalCellSnapshot(text: String($0), width: 1, attribute: .empty) }
        let expression = try #require(TextSearch.expression(for: "ok", options: FindOptions()))
        let matches = TerminalFinder.matches(of: expression, in: [TerminalContentRowSnapshot(absoluteRow: 0, cells: cells)])
        #expect(matches.map(\.runs) == [[.init(row: 0, columns: 2..<4)]])
    }

    @Test func countsStepsAndWrapsAroundThroughTheScrollback() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let pane = env.makePane()
        defer { pane.shutDown() }
        let window = makeTestWindow()
        defer { window.close() }
        window.contentView = pane.view
        #expect(await waitUntil { pane.terminal.process.running })
        pane.terminal.feed(text: "\r\nfirst needle\r\n" + String(repeating: "hay\r\n", count: 80) + "second needle\r\nlast NEEDLE\r\n")
        #expect(await waitUntil { pane.terminal.visibleRowsText(0..<40).joined().contains("NEEDLE") })

        let finder = pane.view.finder
        finder.open(query: "needle")
        #expect(finder.isOpen)
        #expect(finder.matches.count == 3)
        // The one nearest the bottom of the screen comes first.
        #expect(finder.current == 2)
        finder.perform(.next)
        #expect(finder.current == 0)
        finder.perform(.previous)
        #expect(finder.current == 2)

        // Searching again keeps the current match, and new output doesn't move it.
        finder.perform(.previous)
        finder.open(query: "needle")
        #expect(finder.current == 1)
        // Printed by the shell, as output is; the command line doesn't hold the word itself.
        pane.terminal.send(txt: "printf 'nee''dle\\n'\r")
        #expect(await waitUntil { finder.matches.count == 4 })
        #expect(finder.current == 1)
        finder.open(query: "nothing like it")
        #expect(finder.matches.isEmpty)
        #expect(finder.current == nil)

        finder.close()
        #expect(!finder.isOpen)
        #expect(finder.matches.isEmpty)
    }
}
