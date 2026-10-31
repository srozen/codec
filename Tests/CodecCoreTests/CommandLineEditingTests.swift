import Testing
import CoreGraphics
@testable import CodecCore

@Suite("CommandLineEditing")
struct CommandLineEditingUnitTests {
    typealias Action = CommandLineEditing.Action

    private func decode(_ bytes: [UInt8]) -> [Action] {
        String(decoding: bytes, as: UTF8.self)
            .components(separatedBy: "\u{1b}[").dropFirst()
            .compactMap { Int($0.dropLast()).flatMap(Action.init(rawValue:)) }
    }

    @Test func sequencesAreDistinctPrivateKeys() {
        let sequences = Action.allCases.map(\.sequence)
        #expect(Set(sequences.map { String(decoding: $0, as: UTF8.self) }).count == Action.allCases.count)
        #expect(Action.mark.sequence == Array("\u{1b}[57001~".utf8))
    }

    @Test func stepsMoveEitherWay() {
        #expect(decode(CommandLineEditing.steps(3)) == [.stepRight, .stepRight, .stepRight])
        #expect(decode(CommandLineEditing.steps(-2)) == [.stepLeft, .stepLeft])
        #expect(CommandLineEditing.steps(0).isEmpty)
    }

    /// Both ends are measured from the original cursor, in either drag direction.
    @Test(arguments: [(-5, 2), (2, -5)])
    func selectionAnchorsBothEndsToTheCursor(a: Int, b: Int) {
        #expect(decode(CommandLineEditing.select(from: a, to: b)) ==
                [.unmark, .saveCursor] + Array(repeating: .stepLeft, count: 5) + [.mark, .restoreCursor, .stepRight, .stepRight])
    }

    @Test func pressAnchorsAndDragsMeasureFromTheAnchor() {
        #expect(decode(CommandLineEditing.press(at: -2)) == [.unmark, .stepLeft, .stepLeft, .setAnchor])
        #expect(decode(CommandLineEditing.drag(to: 3)) == [.toAnchor, .mark, .stepRight, .stepRight, .stepRight])
        #expect(decode(CommandLineEditing.drag(to: -1)) == [.toAnchor, .mark, .stepLeft])
        #expect(decode(CommandLineEditing.drag(to: 0)) == [.toAnchor, .unmark])
    }

    @Test func offsetsSpanWrappedRows() {
        #expect(CommandLineEditing.offset(of: .init(row: 0, boundary: -3), columns: 80) == -3)
        #expect(CommandLineEditing.offset(of: .init(row: 1, boundary: -70), columns: 80) == 10)
        #expect(CommandLineEditing.offset(of: .init(row: -1, boundary: 5), columns: 80) == -75)
    }

    @Test func onlyLineMovesFallBackToReadline() {
        #expect(Action.moveToStart.readlineFallback == [0x01])
        #expect(Action.moveToEnd.readlineFallback == [0x05])
        #expect(Action.deleteToStart.readlineFallback == [0x15])
        #expect(Action.selectAll.readlineFallback == nil)
        #expect(Action.cut.readlineFallback == nil)
    }

    @Test func locatesPointsAgainstTheCursorCell() {
        // Cursor cell at x 100–110, rows 20 pt high, top of the cursor's row at y 200 (bottom-up).
        let caret = CGRect(x: 100, y: 180, width: 10, height: 20)
        #expect(CommandLineEditing.hit(CGPoint(x: 100, y: 190), caret: caret) == .init(row: 0, boundary: 0))
        #expect(CommandLineEditing.hit(CGPoint(x: 104, y: 195), caret: caret) == .init(row: 0, boundary: 0))
        #expect(CommandLineEditing.hit(CGPoint(x: 106, y: 181), caret: caret) == .init(row: 0, boundary: 1))
        #expect(CommandLineEditing.hit(CGPoint(x: 52, y: 190), caret: caret) == .init(row: 0, boundary: -5))
        #expect(CommandLineEditing.hit(CGPoint(x: 100, y: 230), caret: caret)?.row == -2)
        #expect(CommandLineEditing.hit(CGPoint(x: 100, y: 170), caret: caret)?.row == 1)
        #expect(CommandLineEditing.hit(.zero, caret: .zero) == nil)
    }
}
