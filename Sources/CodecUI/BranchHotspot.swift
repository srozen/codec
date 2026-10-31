import AppKit

/// Sits over the branch in the prompt to show a pointing hand there. Clicks go through to the terminal,
/// which works out what was clicked from the screen's content.
final class BranchHotspot: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        toolTip = "Switch branch"
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    /// Moves over `frame` (the terminal's coordinates), or hides when there's nothing to click.
    func place(at frame: NSRect?) {
        let hidden = frame == nil
        guard hidden != isHidden || (frame != nil && frame != self.frame) else { return }
        if let frame { self.frame = frame }
        isHidden = hidden
        window?.invalidateCursorRects(for: self)
    }
}
