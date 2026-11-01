import Foundation
import CoreGraphics

/// The windows, tabs and splits open when Codec last ran, to open them again at launch: where each
/// pane was, not what ran in it.
public struct SavedWorkspace: Codable, Equatable, Sendable {
    /// Front to back.
    public var windows: [SavedWindow]

    public init(windows: [SavedWindow]) {
        self.windows = windows
    }

    public static let empty = SavedWorkspace(windows: [])

    static let defaultsKey = "SavedWorkspace"

    /// What was saved in `defaults`, if anything readable was.
    public static func load(from defaults: UserDefaults) -> SavedWorkspace? {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(SavedWorkspace.self, from: $0) }
    }

    public func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

public struct SavedWindow: Codable, Equatable, Sendable {
    /// In screen coordinates, as `NSWindow.frame` has it.
    public var frame: CGRect?
    public var tabs: [SavedTab]
    public var selectedTab: Int

    public init(frame: CGRect?, tabs: [SavedTab], selectedTab: Int) {
        self.frame = frame
        self.tabs = tabs
        self.selectedTab = selectedTab
    }
}

public struct SavedTab: Codable, Equatable, Sendable {
    /// The name the user gave it, if any.
    public var title: String?
    public var layout: SavedLayout
    /// The focused pane, in reading order.
    public var focusedPane: Int

    public init(title: String?, layout: SavedLayout, focusedPane: Int) {
        self.title = title
        self.layout = layout
        self.focusedPane = focusedPane
    }
}

/// A tab's panes, as `SplitLayout` arranges them: each with its working directory and, when what it
/// showed was kept, the name it was kept under; each split with its children's shares of its length.
public indirect enum SavedLayout: Codable, Equatable, Sendable {
    case pane(directory: String, contents: String? = nil)
    case split(SplitAxis, [SavedLayout], sizes: [Double]? = nil)

    public var paneCount: Int {
        switch self {
        case .pane: 1
        case .split(_, let children, _): children.reduce(0) { $0 + $1.paneCount }
        }
    }

    /// Builds the layout, making a pane for each directory (and kept contents), in reading order, and
    /// handing each split its saved sizes. Splits left with fewer than two children (from a damaged
    /// file) collapse; nil when there's no pane at all.
    public func build<Leaf: AnyObject>(_ makePane: (_ directory: String, _ contents: String?) -> Leaf,
                                       sizes: (SplitLayout<Leaf>, [Double]) -> Void = { _, _ in }) -> SplitLayout<Leaf>? {
        switch self {
        case .pane(let directory, let contents):
            return .leaf(makePane(directory, contents))
        case .split(let axis, let children, let shares):
            let built = children.compactMap { $0.build(makePane, sizes: sizes) }
            switch built.count {
            case 0: return nil
            case 1: return built[0]
            default:
                let split = SplitLayout.split(axis, built)
                // Sizes for children that were all built.
                if let shares, shares.count == built.count { sizes(split, shares) }
                return split
            }
        }
    }
}

extension SplitLayout {
    /// The layout to save, with each pane's directory and kept contents, and each split's sizes.
    public func saved(directory: (Leaf) -> String, contents: (Leaf) -> String? = { _ in nil },
                      sizes: (SplitLayout) -> [Double]? = { _ in nil }) -> SavedLayout {
        switch self {
        case .leaf(let leaf):
            .pane(directory: directory(leaf), contents: contents(leaf))
        case .split(let axis, let children):
            .split(axis, children.map { $0.saved(directory: directory, contents: contents, sizes: sizes) }, sizes: sizes(self))
        }
    }

    /// For a split, the first pane of each child: what identifies the split from one layout to the
    /// next, as panes come and go. Empty for a leaf.
    public var childAnchors: [Leaf] {
        guard case .split(_, let children) = self else { return [] }
        return children.map { $0.leaves[0] }
    }

    public var axis: SplitAxis? {
        if case .split(let axis, _) = self { return axis }
        return nil
    }
}

/// How the children of a split share its length, as fractions adding up to 1.
public enum SplitShares {
    /// Equal shares.
    public static func even(_ count: Int) -> [Double] {
        count > 0 ? Array(repeating: 1 / Double(count), count: count) : []
    }

    /// Carries shares over to a split whose children changed: children it had keep their share, one
    /// that's new takes half of the share of the one before it (the pane it was split from), and
    /// ones that left give theirs back to the rest.
    public static func carry<Key: Hashable>(_ shares: [Double], from old: [Key], to new: [Key]) -> [Double] {
        guard shares.count == old.count, !new.isEmpty else { return even(new.count) }
        let previous = Dictionary(zip(old, shares), uniquingKeysWith: { first, _ in first })
        var result: [Double] = []
        for key in new {
            if let share = previous[key] {
                result.append(share)
            } else if let last = result.indices.last {
                result[last] /= 2
                result.append(result[last])
            } else {
                result.append(-1)
            }
        }
        // A new first child: half of the one after it.
        if result.first == -1 {
            if let next = result.indices.first(where: { result[$0] > 0 }) {
                result[next] /= 2
                for index in 0..<next { result[index] = result[next] / Double(next) }
            } else {
                return even(new.count)
            }
        }
        return normalized(result)
    }

    /// Scaled to add up to 1; even shares when that isn't possible.
    public static func normalized(_ shares: [Double]) -> [Double] {
        let total = shares.reduce(0, +)
        guard total > 0, shares.allSatisfy({ $0 > 0 && $0.isFinite }) else { return even(shares.count) }
        return shares.map { $0 / total }
    }
}

extension SavedWorkspace {
    /// `directory`, or the nearest folder above it that still exists, or the home folder: a project
    /// may have moved since.
    public static func existingDirectory(_ directory: String, home: String = NSHomeDirectory(),
                                         fileManager: FileManager = .default) -> String {
        var path = directory
        while !path.isEmpty {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue { return path }
            if path == "/" { break }
            path = (path as NSString).deletingLastPathComponent
        }
        return home
    }
}

/// What a pane showed and the commands it ran, kept when Codec quits (or its tab closes) so it can
/// show them again.
public struct SavedPaneContents: Codable, Equatable, Sendable {
    /// The scrollback, as text with its colors and styles in escape sequences, ready to be printed
    /// again. Rows are counted from its first line.
    public var transcript: String
    /// The commands, placed on the transcript's rows.
    public var timeline: CommandTimeline
    /// The id the Commands sidebar listed from (its bin hides older ones).
    public var listStart: Int
    public var saved: Date

    public init(transcript: String, timeline: CommandTimeline, listStart: Int, saved: Date) {
        self.transcript = transcript
        self.timeline = timeline
        self.listStart = listStart
        self.saved = saved
    }
}
