import Testing
import CoreGraphics
@testable import CodecCore

final class Leaf: CustomStringConvertible {
    let name: String
    init(_ name: String) { self.name = name }
    var description: String { name }
}

@Suite("SplitLayout")
struct SplitLayoutTests {
    let a = Leaf("a"), b = Leaf("b"), c = Leaf("c"), d = Leaf("d")

    private func names(_ layout: SplitLayout<Leaf>?) -> [String] {
        layout?.leaves.map(\.name) ?? []
    }

    /// A compact description: leaves by name, splits as h(...) or v(...).
    private func shape(_ layout: SplitLayout<Leaf>) -> String {
        switch layout {
        case .leaf(let leaf): leaf.name
        case .split(let axis, let children):
            (axis == .horizontal ? "h(" : "v(") + children.map(shape).joined(separator: ",") + ")"
        }
    }

    /// What the Commands sidebar calls each pane when it lists every pane's commands.
    @Test func namesEachLeafByWhereItIs() {
        #expect(SplitLayout.leaf(a).placeNames == [nil])
        #expect(SplitLayout.split(.horizontal, [.leaf(a), .leaf(b)]).placeNames == ["left", "right"])
        #expect(SplitLayout.split(.vertical, [.leaf(a), .leaf(b), .leaf(c)]).placeNames == ["top", "middle", "bottom"])
        #expect(SplitLayout.split(.horizontal, [.leaf(a), .split(.vertical, [.leaf(b), .leaf(c)])]).placeNames
            == ["left", "top right", "bottom right"])
        #expect(SplitLayout.split(.vertical, [.split(.horizontal, [.leaf(a), .leaf(b)]), .leaf(c)]).placeNames
            == ["top left", "top right", "bottom"])
        // Too many, or nested too deep, to say in a few words: numbered.
        #expect(SplitLayout.split(.horizontal, [.leaf(a), .leaf(b), .leaf(c), .leaf(d)]).placeNames
            == ["pane 1", "pane 2", "pane 3", "pane 4"])
        let deep = SplitLayout.split(.horizontal, [.leaf(a), .split(.vertical, [.split(.horizontal, [.leaf(b), .leaf(c)]), .leaf(d)])])
        #expect(deep.placeNames == ["pane 1", "pane 2", "pane 3", "pane 4"])
    }

    @Test func singleLeafContainsOnlyItself() {
        let layout = SplitLayout.leaf(a)
        #expect(names(layout) == ["a"])
        #expect(layout.contains(a))
        #expect(!layout.contains(b))
    }

    @Test func splittingALeafCreatesASplitAfterIt() {
        let layout = SplitLayout.leaf(a).splitting(a, with: b, axis: .horizontal)
        #expect(shape(layout) == "h(a,b)")
    }

    @Test func splittingAlongTheSameAxisJoinsTheExistingSplit() {
        let layout = SplitLayout.leaf(a)
            .splitting(a, with: b, axis: .horizontal)
            .splitting(a, with: c, axis: .horizontal)
        #expect(shape(layout) == "h(a,c,b)")
    }

    @Test func splittingAlongTheOtherAxisNests() {
        let layout = SplitLayout.leaf(a)
            .splitting(a, with: b, axis: .horizontal)
            .splitting(b, with: c, axis: .vertical)
        #expect(shape(layout) == "h(a,v(b,c))")
    }

    @Test func splittingBeforePlacesTheNewLeafFirst() {
        #expect(shape(SplitLayout.leaf(a).splitting(a, with: b, axis: .horizontal, before: true)) == "h(b,a)")
        let joined = SplitLayout.leaf(a)
            .splitting(a, with: b, axis: .horizontal)
            .splitting(b, with: c, axis: .horizontal, before: true)
        #expect(shape(joined) == "h(a,c,b)")
        let nested = SplitLayout.leaf(a)
            .splitting(a, with: b, axis: .horizontal)
            .splitting(b, with: c, axis: .vertical, before: true)
        #expect(shape(nested) == "h(a,v(c,b))")
    }

    @Test func splittingAMissingLeafChangesNothing() {
        let layout = SplitLayout.leaf(a).splitting(b, with: c, axis: .vertical)
        #expect(shape(layout) == "a")
    }

    @Test func removingTheOnlyLeafEmptiesTheLayout() {
        #expect(SplitLayout.leaf(a).removing(a) == nil)
    }

    @Test func removingALeafCollapsesItsSplit() {
        let layout = SplitLayout.leaf(a).splitting(a, with: b, axis: .horizontal)
        let removed = layout.removing(a)
        #expect(removed.map(shape) == "b")
    }

    @Test func removingFlattensSplitsThatEndUpAlongTheSameAxis() {
        // h(a, v(b, h(c, d))) minus b → h(a, c, d)
        let layout = SplitLayout.leaf(a)
            .splitting(a, with: b, axis: .horizontal)
            .splitting(b, with: c, axis: .vertical)
            .splitting(c, with: d, axis: .horizontal)
        #expect(shape(layout) == "h(a,v(b,h(c,d)))")
        #expect(layout.removing(b).map(shape) == "h(a,c,d)")
    }

    @Test func removingAMissingLeafKeepsTheLayout() {
        let layout = SplitLayout.leaf(a).splitting(a, with: b, axis: .vertical)
        #expect(layout.removing(c).map(shape) == "v(a,b)")
    }

    @Test func leavesAreInReadingOrder() {
        let layout = SplitLayout.leaf(a)
            .splitting(a, with: b, axis: .horizontal)
            .splitting(a, with: c, axis: .vertical)
        #expect(names(layout) == ["a", "c", "b"])
    }

    @Test(arguments: [true, false])
    func cyclingWrapsAround(forward: Bool) {
        let layout = SplitLayout.leaf(a)
            .splitting(a, with: b, axis: .horizontal)
            .splitting(b, with: c, axis: .horizontal)
        let start = forward ? c : a
        let expected = forward ? a : c
        #expect(layout.leaf(after: start, forward: forward) === expected)
    }

    @Test func cyclingFromAMissingLeafReturnsTheFirst() {
        #expect(SplitLayout.leaf(a).leaf(after: b) === a)
    }

    @Test func sameShapeComparesLeavesByIdentityAndStructure() {
        let one = SplitLayout.leaf(a).splitting(a, with: b, axis: .horizontal)
        let same = SplitLayout.leaf(a).splitting(a, with: b, axis: .horizontal)
        let otherAxis = SplitLayout.leaf(a).splitting(a, with: b, axis: .vertical)
        let otherLeaf = SplitLayout.leaf(a).splitting(a, with: c, axis: .horizontal)
        #expect(one.isSameShape(as: same))
        #expect(!one.isSameShape(as: otherAxis))
        #expect(!one.isSameShape(as: otherLeaf))
        #expect(!one.isSameShape(as: .leaf(a)))
    }
}

@Suite("PaneGeometry")
struct PaneGeometryTests {
    // A 2×2 grid, top-down coordinates:
    //   tl | tr
    //   bl | br
    let tl = CGRect(x: 0, y: 0, width: 100, height: 100)
    let tr = CGRect(x: 101, y: 0, width: 100, height: 100)
    let bl = CGRect(x: 0, y: 101, width: 100, height: 100)
    let br = CGRect(x: 101, y: 101, width: 100, height: 100)

    private var all: [(id: String, frame: CGRect)] {
        [("tl", tl), ("tr", tr), ("bl", bl), ("br", br)]
    }

    private func neighbor(of frame: CGRect, _ direction: FocusDirection) -> String? {
        PaneGeometry.neighbor(of: frame, toward: direction, among: all.filter { $0.frame != frame })
    }

    @Test func findsNeighborsInEachDirection() {
        #expect(neighbor(of: tl, .right) == "tr")
        #expect(neighbor(of: tl, .down) == "bl")
        #expect(neighbor(of: br, .left) == "bl")
        #expect(neighbor(of: br, .up) == "tr")
    }

    @Test func returnsNilAtTheEdge() {
        #expect(neighbor(of: tl, .left) == nil)
        #expect(neighbor(of: tl, .up) == nil)
    }

    @Test func requiresOverlapOnTheOtherAxis() {
        let wide = CGRect(x: 0, y: 0, width: 201, height: 100)
        let below = CGRect(x: 150, y: 101, width: 51, height: 100)
        let farRight = CGRect(x: 300, y: 300, width: 50, height: 50)
        let candidates = [(id: "below", frame: below), (id: "far", frame: farRight)]
        #expect(PaneGeometry.neighbor(of: wide, toward: .down, among: candidates) == "below")
        #expect(PaneGeometry.neighbor(of: wide, toward: .right, among: candidates) == nil)
    }
}
