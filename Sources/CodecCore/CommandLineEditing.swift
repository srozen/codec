import CoreGraphics

/// Editing the shell's command line like a text field. zsh stays the editor; its region (mark to
/// cursor) is the selection. The terminal translates mouse gestures and macOS shortcuts into key
/// sequences that Codec's zsh integration binds to small widgets.
public enum CommandLineEditing {
    /// Private sequences bound by the integration. No real key sends them, and they're only sent while
    /// the integration is known to be loaded, so they never reach another program.
    public enum Action: Int, CaseIterable, Sendable {
        case mark = 57001
        case stepLeft
        case stepRight
        case unmark
        case cut
        case selectWord
        case selectAll
        case selectToStart
        case selectToEnd
        case deleteToStart
        case moveToStart
        case moveToEnd
        case saveCursor
        case restoreCursor

        /// `ESC [ <code> ~`
        public var sequence: [UInt8] { Array("\u{1b}[\(rawValue)~".utf8) }

        /// What to send instead to a program that isn't Codec's zsh (a REPL, another shell),
        /// using readline's standard keys. Nil when there's no safe equivalent.
        public var readlineFallback: [UInt8]? {
            switch self {
            case .moveToStart: [0x01]
            case .moveToEnd: [0x05]
            case .deleteToStart: [0x15]
            default: nil
            }
        }
    }

    /// Moves the cursor `offset` characters (positive is right) without touching the selection.
    public static func steps(_ offset: Int) -> [UInt8] {
        let step = offset < 0 ? Action.stepLeft : Action.stepRight
        return Array(repeating: step.sequence, count: abs(offset)).flatMap { $0 }
    }

    /// Selects between two positions given relative to the cursor; zsh clamps each to the command line.
    /// Both ends are measured from the original cursor, so clamping one never shifts the other.
    public static func select(from a: Int, to b: Int) -> [UInt8] {
        let start = min(a, b), end = max(a, b)
        return Action.unmark.sequence + Action.saveCursor.sequence + steps(start) + Action.mark.sequence
            + Action.restoreCursor.sequence + steps(end)
    }

    /// Where a point falls relative to the cursor's cell, in cells.
    public struct Hit: Equatable, Sendable {
        /// Rows below the cursor's row (negative above).
        public var row: Int
        /// The cell boundary nearest the point: where a selection edge dragged there lands.
        public var boundary: Int
    }

    /// Locates `point` against the cursor's cell `caret`, both in the same bottom-up coordinates.
    public static func hit(_ point: CGPoint, caret: CGRect) -> Hit? {
        guard caret.width > 0, caret.height > 0 else { return nil }
        let row = Int(((caret.maxY - point.y) / caret.height).rounded(.down))
        let boundary = Int(((point.x - caret.minX) / caret.width).rounded())
        return Hit(row: row, boundary: boundary)
    }
}
