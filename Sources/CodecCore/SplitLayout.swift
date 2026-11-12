import CoreGraphics

/// How a split arranges its children.
public enum SplitAxis: String, Sendable, Equatable, Codable {
    /// Children side by side, left to right.
    case horizontal
    /// Children stacked, top to bottom.
    case vertical
}

/// The arrangement of panes in a tab: a leaf, or a split of two or more children along one axis.
///
/// A value type: every operation returns a new layout. Leaves are compared by identity.
/// Layouts stay normalized: no split has fewer than two children, and no split directly contains
/// a split along the same axis.
public indirect enum SplitLayout<Leaf: AnyObject> {
    case leaf(Leaf)
    case split(SplitAxis, [SplitLayout<Leaf>])

    /// Every leaf, in reading order.
    public var leaves: [Leaf] {
        switch self {
        case .leaf(let leaf): [leaf]
        case .split(_, let children): children.flatMap(\.leaves)
        }
    }

    public func contains(_ target: Leaf) -> Bool {
        leaves.contains { $0 === target }
    }

    /// Places `new` right after `target` along `axis` (right of it or below it), or right before it
    /// (left or above), joining an existing split along the same axis rather than nesting a new one.
    /// Returns the layout unchanged if `target` isn't in it.
    public func splitting(_ target: Leaf, with new: Leaf, axis: SplitAxis, before: Bool = false) -> SplitLayout {
        switch self {
        case .leaf(let leaf):
            guard leaf === target else { return self }
            return .split(axis, before ? [.leaf(new), .leaf(leaf)] : [.leaf(leaf), .leaf(new)])
        case .split(let splitAxis, var children):
            if splitAxis == axis, let index = children.firstIndex(where: { $0.isLeaf(target) }) {
                children.insert(.leaf(new), at: before ? index : index + 1)
                return .split(splitAxis, children)
            }
            return .split(splitAxis, children.map { $0.splitting(target, with: new, axis: axis, before: before) })
        }
    }

    /// Removes `target`, collapsing splits left with a single child. Returns nil when nothing is left.
    public func removing(_ target: Leaf) -> SplitLayout? {
        switch self {
        case .leaf(let leaf):
            return leaf === target ? nil : self
        case .split(let axis, let children):
            let remaining = children.compactMap { $0.removing(target) }
            switch remaining.count {
            case 0: return nil
            case 1: return remaining[0]
            default: return SplitLayout.split(axis, remaining).flattened()
            }
        }
    }

    /// The leaf after (or before) `current` in reading order, wrapping around.
    public func leaf(after current: Leaf, forward: Bool = true) -> Leaf? {
        let all = leaves
        guard let index = all.firstIndex(where: { $0 === current }) else { return all.first }
        return all[(index + (forward ? 1 : all.count - 1)) % all.count]
    }

    /// Whether both layouts hold the same leaves in the same arrangement.
    public func isSameShape(as other: SplitLayout) -> Bool {
        switch (self, other) {
        case (.leaf(let a), .leaf(let b)):
            a === b
        case (.split(let axisA, let a), .split(let axisB, let b)):
            axisA == axisB && a.count == b.count && zip(a, b).allSatisfy { $0.isSameShape(as: $1) }
        default:
            false
        }
    }

    /// What to call each leaf, in reading order, by where it is: "left", "top right". Nil for a lone
    /// leaf, which needs no name. When places can't be told apart in a few words (splits of more than
    /// three, or nested three deep), the leaves are numbered instead: "pane 1", "pane 2".
    public var placeNames: [String?] {
        guard case .split = self else { return [nil] }
        let numbered = leaves.indices.map { Optional("pane \($0 + 1)") }
        guard let places = places(), Set(places).count == places.count else { return numbered }
        return places
    }

    /// Each leaf's place as words for across and down, or nil when one leaf would need two of either.
    private func places() -> [String]? {
        func walk(_ node: SplitLayout, across: String?, down: String?) -> [String]? {
            guard case .split(let axis, let children) = node else {
                return [[down, across].compactMap { $0 }.joined(separator: " ")]
            }
            let words: [String]
            switch (axis, children.count) {
            case (.horizontal, 2): words = ["left", "right"]
            case (.horizontal, 3): words = ["left", "middle", "right"]
            case (.vertical, 2): words = ["top", "bottom"]
            case (.vertical, 3): words = ["top", "middle", "bottom"]
            default: return nil
            }
            if axis == .horizontal ? across != nil : down != nil { return nil }
            var names: [String] = []
            for (child, word) in zip(children, words) {
                guard let inner = walk(child, across: axis == .horizontal ? word : across,
                                       down: axis == .vertical ? word : down) else { return nil }
                names += inner
            }
            return names
        }
        return walk(self, across: nil, down: nil)
    }

    private func isLeaf(_ target: Leaf) -> Bool {
        if case .leaf(let leaf) = self { return leaf === target }
        return false
    }

    /// Merges child splits that run along the same axis as their parent.
    private func flattened() -> SplitLayout {
        guard case .split(let axis, let children) = self else { return self }
        return .split(axis, children.flatMap { child -> [SplitLayout] in
            if case .split(let childAxis, let grandchildren) = child, childAxis == axis {
                return grandchildren
            }
            return [child]
        })
    }
}

/// A direction to move focus between panes.
public enum FocusDirection: Sendable, CaseIterable {
    case left, right, up, down
}

public enum PaneGeometry {
    /// The candidate nearest to `origin` that lies in `direction` and overlaps it on the other axis.
    /// Frames use a top-left origin (y grows downward).
    public static func neighbor<ID>(of origin: CGRect, toward direction: FocusDirection,
                                    among candidates: [(id: ID, frame: CGRect)]) -> ID? {
        let tolerance: CGFloat = 1
        let eligible = candidates.filter { candidate in
            let frame = candidate.frame
            let overlapsVertically = frame.maxY > origin.minY && frame.minY < origin.maxY
            let overlapsHorizontally = frame.maxX > origin.minX && frame.minX < origin.maxX
            switch direction {
            case .left: return frame.maxX <= origin.minX + tolerance && overlapsVertically
            case .right: return frame.minX >= origin.maxX - tolerance && overlapsVertically
            case .up: return frame.maxY <= origin.minY + tolerance && overlapsHorizontally
            case .down: return frame.minY >= origin.maxY - tolerance && overlapsHorizontally
            }
        }
        return eligible.min { a, b in
            distance(origin, a.frame) < distance(origin, b.frame)
        }?.id
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }
}
