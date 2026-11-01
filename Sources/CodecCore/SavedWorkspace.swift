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

/// A tab's panes, as `SplitLayout` arranges them, each with its working directory.
public indirect enum SavedLayout: Codable, Equatable, Sendable {
    case pane(directory: String)
    case split(SplitAxis, [SavedLayout])

    public var paneCount: Int {
        switch self {
        case .pane: 1
        case .split(_, let children): children.reduce(0) { $0 + $1.paneCount }
        }
    }

    /// Builds the layout, making a pane for each directory, in reading order. Splits left with fewer
    /// than two children (from a damaged file) collapse; nil when there's no pane at all.
    public func build<Leaf: AnyObject>(_ makePane: (String) -> Leaf) -> SplitLayout<Leaf>? {
        switch self {
        case .pane(let directory):
            return .leaf(makePane(directory))
        case .split(let axis, let children):
            let built = children.compactMap { $0.build(makePane) }
            switch built.count {
            case 0: return nil
            case 1: return built[0]
            default: return .split(axis, built)
            }
        }
    }
}

extension SplitLayout {
    /// The layout to save, with each pane's directory.
    public func saved(directory: (Leaf) -> String) -> SavedLayout {
        switch self {
        case .leaf(let leaf): .pane(directory: directory(leaf))
        case .split(let axis, let children): .split(axis, children.map { $0.saved(directory: directory) })
        }
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
