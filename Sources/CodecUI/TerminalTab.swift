import AppKit
import Combine
import CodecCore

/// One tab: a layout of panes and which of them has focus.
@MainActor
final class TerminalTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var layout: SplitLayout<Pane> {
        didSet { onLayoutChange?() }
    }
    @Published private(set) var focused: Pane {
        didSet { onLayoutChange?() }
    }
    /// Called synchronously after the layout or the focused pane changed, so the window can update its views.
    var onLayoutChange: (() -> Void)?
    private var sessionObservers: [ObjectIdentifier: AnyCancellable] = [:]

    init(pane: Pane) {
        layout = .leaf(pane)
        focused = pane
        observe(pane)
    }

    var panes: [Pane] { layout.leaves }

    func focus(_ pane: Pane) {
        guard pane !== focused, layout.contains(pane) else { return }
        focused = pane
    }

    /// Splits `pane`, placing `new` after it, and focuses `new`.
    func split(_ pane: Pane, with new: Pane, axis: SplitAxis) {
        guard layout.contains(pane) else { return }
        observe(new)
        layout = layout.splitting(pane, with: new, axis: axis)
        focused = new
    }

    /// Removes `pane`. Returns true when the tab has no panes left.
    @discardableResult
    func remove(_ pane: Pane) -> Bool {
        let previousOrder = panes
        sessionObservers[ObjectIdentifier(pane)] = nil
        guard let remaining = layout.removing(pane) else { return true }
        if focused === pane {
            // Focus the pane that took its place in reading order.
            let index = previousOrder.firstIndex { $0 === pane } ?? 0
            let leaves = remaining.leaves
            focused = leaves[min(index, leaves.count - 1)]
        }
        layout = remaining
        return false
    }

    func cyclePane(forward: Bool) {
        if let next = layout.leaf(after: focused, forward: forward) { focus(next) }
    }

    /// Focuses the nearest pane on screen in `direction`.
    func focusNeighbor(_ direction: FocusDirection) {
        func frame(_ pane: Pane) -> CGRect {
            // Window coordinates are bottom-up; PaneGeometry expects top-down.
            let rect = pane.view.convert(pane.view.bounds, to: nil)
            return CGRect(x: rect.minX, y: -rect.maxY, width: rect.width, height: rect.height)
        }
        let candidates = panes.filter { $0 !== focused }.map { (id: ObjectIdentifier($0), frame: frame($0)) }
        guard let target = PaneGeometry.neighbor(of: frame(focused), toward: direction, among: candidates),
              let pane = panes.first(where: { ObjectIdentifier($0) == target }) else { return }
        focus(pane)
    }

    /// Re-publishes changes of every pane's session so tab titles and indicators stay current.
    private func observe(_ pane: Pane) {
        sessionObservers[ObjectIdentifier(pane)] = pane.session.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
    }

    /// Builds the view hierarchy for the current layout.
    func makeView(divider: NSColor) -> NSView {
        func build(_ node: SplitLayout<Pane>) -> NSView {
            switch node {
            case .leaf(let pane):
                pane.view.removeFromSuperview()
                return pane.view
            case .split(let axis, let children):
                let split = PaneSplitView()
                split.isVertical = axis == .horizontal
                split.dividerStyle = .thin
                split.divider = divider
                children.map(build).forEach(split.addArrangedSubview)
                return split
            }
        }
        return build(layout)
    }
}

/// A split view with a hairline divider that spreads its panes evenly the first time it's laid out.
final class PaneSplitView: NSSplitView {
    var divider: NSColor = .separatorColor
    private var distributed = false

    override var dividerColor: NSColor { divider }
    override var dividerThickness: CGFloat { 1 }

    override func layout() {
        super.layout()
        guard !distributed, arrangedSubviews.count > 1 else { return }
        let total = isVertical ? bounds.width : bounds.height
        guard total > 0 else { return }
        distributed = true
        let count = CGFloat(arrangedSubviews.count)
        let share = (total - dividerThickness * (count - 1)) / count
        for index in 0..<(arrangedSubviews.count - 1) {
            setPosition(share * CGFloat(index + 1) + dividerThickness * CGFloat(index), ofDividerAt: index)
        }
    }
}
