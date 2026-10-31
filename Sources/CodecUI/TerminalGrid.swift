import AppKit
import SwiftTerm

/// Maps between window points and the terminal cells on screen, and reads their text.
///
/// SwiftTerm lays cells out from the view's top-left corner with no padding, but doesn't expose the cell
/// size; that comes from the caret, which is one cell (or two, on a wide character). Only the caret's size
/// is used: its position is updated on the next display frame, so it can lag behind fast output.
@MainActor
struct TerminalGrid {
    /// The terminal view's bounds, in window coordinates (bottom-up).
    let frame: CGRect
    let cellSize: CGSize
    let columns: Int
    /// The rows on screen, top to bottom, numbered in SwiftTerm's scroll-invariant coordinates.
    let rows: [TerminalContentRowSnapshot]
    let cursorVisibleRow: Int
    let cursorColumn: Int
    /// Converts scroll-invariant rows to the rows `TerminalView.scrollTo(row:)` takes.
    let bufferRowOffset: Int

    init?(terminal: TerminalView) {
        guard let window = terminal.window,
              let snapshot = terminal.terminalContentSnapshot(region: .viewport),
              let top = snapshot.rows.first?.absoluteRow else { return nil }
        let caretOnScreen = terminal.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        guard caretOnScreen.width > 0, caretOnScreen.height > 0 else { return nil }
        let caret = window.convertFromScreen(caretOnScreen)
        frame = terminal.convert(terminal.bounds, to: nil)
        columns = snapshot.inputState.dimensions.cols
        rows = snapshot.rows
        cursorVisibleRow = snapshot.cursorRow - top
        cursorColumn = snapshot.cursorColumn
        // The caret spans a wide character's two cells.
        let cursorCells = rows.indices.contains(cursorVisibleRow)
            ? rows[cursorVisibleRow].cells.dropFirst(cursorColumn).first.map { max($0.width, 1) } ?? 1 : 1
        cellSize = CGSize(width: caret.width / CGFloat(cursorCells), height: caret.height)
        bufferRowOffset = top - terminal.terminalStateSnapshot().viewportRow
    }

    var viewportTop: Int { rows.first?.absoluteRow ?? 0 }

    /// The cursor's cell, in window coordinates.
    var caret: CGRect { frame(row: cursorVisibleRow, columns: cursorColumn..<(cursorColumn + 1)) }

    /// Some cells of a visible row, in window coordinates.
    func frame(row: Int, columns: Range<Int>) -> CGRect {
        CGRect(x: frame.minX + CGFloat(columns.lowerBound) * cellSize.width,
               y: frame.maxY - CGFloat(row + 1) * cellSize.height,
               width: CGFloat(columns.count) * cellSize.width, height: cellSize.height)
    }

    /// The visible row and column under a window point. Rows can fall outside the screen.
    func cell(at point: NSPoint) -> (row: Int, column: Int) {
        let row = Int(((frame.maxY - point.y) / cellSize.height).rounded(.down))
        let column = Int(((point.x - frame.minX) / cellSize.width).rounded(.down))
        return (row, min(max(column, 0), columns - 1))
    }

    /// The window point at the center of a cell.
    func center(row: Int, column: Int) -> NSPoint {
        NSPoint(x: frame.minX + (CGFloat(column) + 0.5) * cellSize.width,
                y: frame.maxY - (CGFloat(row) + 0.5) * cellSize.height)
    }

    /// A window point just past a cell's right edge: where a drag must end to include that cell, since
    /// the terminal treats a selection's end as exclusive.
    func trailingEdge(row: Int, column: Int) -> NSPoint {
        NSPoint(x: frame.minX + CGFloat(column + 1) * cellSize.width + 1,
                y: frame.maxY - (CGFloat(row) + 0.5) * cellSize.height)
    }

    /// A visible row's characters, each with the column it starts at and how many columns it covers.
    func cells(ofRow row: Int) -> [(character: Character, column: Int, width: Int)] {
        guard rows.indices.contains(row) else { return [] }
        var cells: [(character: Character, column: Int, width: Int)] = []
        var column = 0
        for cell in rows[row].cells {
            defer { column += cell.width }
            guard cell.width > 0 else { continue }
            cells.append((cell.text.first ?? " ", column, cell.width))
        }
        return cells
    }

    /// The logical line around a visible row, with soft-wrapped rows joined, and the cell of each character.
    func logicalLine(containing row: Int) -> (characters: [Character], cells: [(row: Int, column: Int)])? {
        guard rows.indices.contains(row) else { return nil }
        var first = row, last = row
        while first > 0, rows[first].isWrapped { first -= 1 }
        while last + 1 < rows.count, rows[last + 1].isWrapped { last += 1 }
        var characters: [Character] = []
        var cells: [(row: Int, column: Int)] = []
        for index in first...last {
            var column = 0
            for cell in rows[index].cells {
                // A wide character's cell is followed by a zero-width placeholder.
                defer { column += cell.width }
                guard cell.width > 0 else { continue }
                characters.append(cell.text.first ?? " ")
                cells.append((index, column))
            }
            // Rows are as wide as the terminal; pad short ones so every column maps to a character.
            while column < columns {
                characters.append(" ")
                cells.append((index, column))
                column += 1
            }
        }
        return (characters, cells)
    }
}
