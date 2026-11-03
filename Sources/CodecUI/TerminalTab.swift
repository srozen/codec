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
    /// A name the user gave the tab. Nil means the title follows the focused pane.
    @Published private(set) var customTitle: String?
    /// Called synchronously after the layout or the focused pane changed, so the window can update its views.
    var onLayoutChange: (() -> Void)?
    private var sessionObservers: [ObjectIdentifier: AnyCancellable] = [:]

    /// A split, told apart from the others by its axis and the first pane of each of its children.
    struct SplitKey: Hashable {
        let axis: SplitAxis
        let anchors: [ObjectIdentifier]

        init?(_ node: SplitLayout<Pane>) {
            guard let axis = node.axis else { return nil }
            self.axis = axis
            anchors = node.childAnchors.map(ObjectIdentifier.init)
        }

        init(axis: SplitAxis, anchors: [ObjectIdentifier]) {
            self.axis = axis
            self.anchors = anchors
        }

        /// The keys of a layout's splits, nested ones included.
        static func all(in node: SplitLayout<Pane>) -> [SplitKey] {
            guard case .split(_, let children) = node, let key = SplitKey(node) else { return [] }
            return [key] + children.flatMap(all)
        }
    }

    /// How each split shares its length between its children, as the user left it.
    private(set) var shares: [SplitKey: [Double]] = [:]

    init(pane: Pane) {
        layout = .leaf(pane)
        focused = pane
        observe(pane)
    }

    /// A tab with panes already arranged, as when it's reopened, with its splits' sizes.
    init(layout: SplitLayout<Pane>, focused: Pane, shares: [SplitKey: [Double]] = [:]) {
        self.layout = layout
        self.focused = layout.contains(focused) ? focused : layout.leaves[0]
        self.shares = shares
        layout.leaves.forEach(observe)
    }

    /// What to save of it, to open it again; `contents` names what each pane showed, when it was kept.
    func saved(contents: (Pane) -> String? = { _ in nil }) -> SavedTab {
        SavedTab(title: customTitle,
                 layout: layout.saved(directory: { $0.session.directory }, contents: contents, sizes: { self.shares(for: $0) }),
                 focusedPane: panes.firstIndex { $0 === focused } ?? 0)
    }

    // MARK: Split sizes

    /// A split's sizes: as it was left, or carried over from the split it was before panes came or
    /// went, or even.
    func shares(for node: SplitLayout<Pane>) -> [Double] {
        guard let key = SplitKey(node) else { return [] }
        if let known = shares[key] { return known }
        let anchors = Set(key.anchors)
        let closest = shares.filter { $0.key.axis == key.axis }
            .map { (entry: $0, common: anchors.intersection($0.key.anchors).count) }
            .filter { $0.common > 0 }
            .max { $0.common < $1.common }
        guard let closest else { return SplitShares.even(key.anchors.count) }
        return SplitShares.carry(closest.entry.value, from: closest.entry.key.anchors, to: key.anchors)
    }

    /// The user dragged a divider, or the split was laid out.
    private func split(_ key: SplitKey, resizedTo new: [Double]) {
        if let old = shares[key], old.count == new.count, zip(old, new).allSatisfy({ abs($0 - $1) < 0.002 }) { return }
        shares[key] = new
        // So the window saves it.
        objectWillChange.send()
    }

    var panes: [Pane] { layout.leaves }

    /// What the tab bar and the window title show.
    var title: String { customTitle ?? automaticTitle }

    /// The title the tab has without a custom name: what's running in its focused pane.
    var automaticTitle: String { focused.session.title }

    /// Names the tab. Blank names (or nil) go back to the automatic title.
    func rename(to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let newTitle = trimmed.isEmpty ? nil : trimmed
        if newTitle != customTitle { customTitle = newTitle }
    }

    func focus(_ pane: Pane) {
        guard pane !== focused, layout.contains(pane) else { return }
        focused = pane
    }

    /// Splits `pane`, placing `new` after it (or before it), and focuses `new`.
    func split(_ pane: Pane, with new: Pane, axis: SplitAxis, before: Bool = false) {
        guard layout.contains(pane) else { return }
        observe(new)
        let split = layout.splitting(pane, with: new, axis: axis, before: before)
        // Before the views are laid out for the new layout, which reads the sizes.
        if before { moveShares(from: pane, to: new, in: split) }
        layout = split
        focused = new
    }

    /// Splits' sizes are keyed by the first pane of each child, and a pane split before takes that place
    /// from `pane`: the sizes of the splits around it carry over to `new`, and in a split `new` joined,
    /// it takes half of `pane`'s share, as a pane split after does.
    private func moveShares(from pane: Pane, to new: Pane, in split: SplitLayout<Pane>) {
        let old = ObjectIdentifier(pane), added = ObjectIdentifier(new)
        let keys = Set(SplitKey.all(in: split))
        for (key, value) in shares {
            guard let index = key.anchors.firstIndex(of: old) else { continue }
            var anchors = key.anchors
            anchors[index] = added
            let replaced = SplitKey(axis: key.axis, anchors: anchors)
            anchors.insert(old, at: index + 1)
            let joined = SplitKey(axis: key.axis, anchors: anchors)
            if keys.contains(replaced) {
                shares[replaced] = value
            } else if keys.contains(joined), value.indices.contains(index) {
                var halved = value
                halved[index] /= 2
                halved.insert(halved[index], at: index)
                shares[joined] = halved
            } else {
                continue
            }
            shares[key] = nil
        }
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

    /// Builds the view hierarchy for the current layout, each split at the size it was left at.
    func makeView(divider: NSColor) -> NSView {
        var current: [SplitKey: [Double]] = [:]
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
                if let key = SplitKey(node) {
                    let shares = shares(for: node)
                    current[key] = shares
                    split.shares = shares
                    split.onResize = { [weak self] shares in self?.split(key, resizedTo: shares) }
                }
                return split
            }
        }
        let root = build(layout)
        // Splits that are gone are forgotten.
        shares = current
        return root
    }
}

/// A split view with a hairline divider that sizes its panes by `shares` (evenly without) the first
/// time it's laid out, and reports their shares when they change.
final class PaneSplitView: NSSplitView, NSSplitViewDelegate {
    var divider: NSColor = .separatorColor
    /// Each pane's fraction of the length, adding up to 1.
    var shares: [Double]?
    var onResize: (([Double]) -> Void)?
    private var distributed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var dividerColor: NSColor { divider }
    override var dividerThickness: CGFloat { 1 }

    private var length: CGFloat { isVertical ? bounds.width : bounds.height }

    override func layout() {
        super.layout()
        guard !distributed, arrangedSubviews.count > 1 else { return }
        let count = arrangedSubviews.count
        let available = length - dividerThickness * CGFloat(count - 1)
        guard available > 0 else { return }
        let fractions = shares.flatMap { $0.count == count ? $0 : nil } ?? SplitShares.even(count)
        // Before moving dividers, which lays the view out again.
        distributed = true
        var position: CGFloat = 0
        for index in 0..<(count - 1) {
            position += available * CGFloat(fractions[index])
            setPosition(position.rounded(), ofDividerAt: index)
            position += dividerThickness
        }
        reportShares()
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard distributed else { return }
        reportShares()
    }

    private func reportShares() {
        let sizes = arrangedSubviews.map { isVertical ? $0.frame.width : $0.frame.height }
        let total = sizes.reduce(0, +)
        guard total > 0, sizes.allSatisfy({ $0 > 0 }) else { return }
        let measured = sizes.map { Double($0 / total) }
        shares = measured
        onResize?(measured)
    }
}
