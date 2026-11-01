import AppKit
import Combine
import CodecCore

/// The Intel a window can see: the user's own, and the focused pane's project's, kept in its repository
/// under `.codec/intel` so it can be committed and shared. Each item is a Markdown file; the library
/// reads both folders, and rereads them when they change on disk.
@MainActor
final class IntelLibrary: ObservableObject {
    enum Source: Equatable, Hashable {
        case project
        case personal
    }

    struct Entry: Identifiable, Equatable {
        let url: URL
        let source: Source
        var item: IntelItem
        /// The subfolder it's in, if any, relative to its library's folder.
        var folder: String

        var id: String { url.path }
    }

    /// A subfolder of a library's folder, to group items in.
    struct Folder: Identifiable, Equatable, Hashable {
        let source: Source
        /// Relative to its library's folder, `/`-separated.
        let path: String

        var id: String { "\(source == .project ? "project" : "personal"):\(path)" }
        var name: String { (path as NSString).lastPathComponent }
        /// The folder it's in: "" for the top.
        var parent: String { (path as NSString).deletingLastPathComponent }
        var depth: Int { path.split(separator: "/").count }

        /// Whether `other` is this folder or inside it.
        func contains(_ source: Source, _ other: String) -> Bool {
            source == self.source && (other == path || other.hasPrefix(path + "/"))
        }
    }

    enum Failure: LocalizedError {
        case badName
        case exists(String)
        case intoItself

        var errorDescription: String? {
            switch self {
            case .badName: "A folder name can’t be empty, start with a dot, or contain “/” or “:”."
            case .exists(let name): "There’s already a folder named “\(name)” there."
            case .intoItself: "A folder can’t go inside itself."
            }
        }
    }

    /// `~/.codec/intel`: easy to find, back up, or keep in a dotfiles repository.
    static let standardPersonalFolder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codec/intel", isDirectory: true)
    static let projectSubfolder = ".codec/intel"

    let personalFolder: URL
    /// The focused pane's repository, when it's in one.
    @Published private(set) var projectRoot: URL?
    @Published private(set) var personal: [Entry] = []
    @Published private(set) var project: [Entry] = []
    /// Every subfolder of both, empty ones too, sorted.
    @Published private(set) var folders: [Folder] = []

    /// Watches the folders while the Intel tab is showing.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if isActive { reload() }
            watch()
        }
    }

    private var watchers: [FileWatcher] = []

    init(personalFolder: URL) {
        self.personalFolder = personalFolder.standardizedFileURL
    }

    var projectFolder: URL? {
        projectRoot?.appendingPathComponent(Self.projectSubfolder, isDirectory: true)
    }

    var projectName: String? { projectRoot?.lastPathComponent }

    var entries: [Entry] { project + personal }

    func folder(for source: Source) -> URL? {
        source == .personal ? personalFolder : projectFolder
    }

    /// A subfolder's location on disk; "" is the library's folder itself.
    func url(ofFolder path: String, in source: Source) -> URL? {
        guard let root = folder(for: source) else { return nil }
        return path.isEmpty ? root : root.appendingPathComponent(path, isDirectory: true)
    }

    func folders(in source: Source) -> [Folder] {
        folders.filter { $0.source == source }
    }

    /// Follows the focused pane: its repository's Intel is the project's.
    func follow(_ directory: String) {
        guard !directory.isEmpty else { return }
        let root = GitInfo.workTreeRoot(containing: URL(fileURLWithPath: directory, isDirectory: true))?.standardizedFileURL
        guard root?.path != projectRoot?.path else { return }
        projectRoot = root
        if isActive {
            reload()
            watch()
        }
    }

    // MARK: Reading

    func reload() {
        let personal = Self.read(personalFolder, source: .personal)
        let project = projectFolder.map { Self.read($0, source: .project) } ?? (entries: [], folders: [])
        if personal.entries != self.personal { self.personal = personal.entries }
        if project.entries != self.project { self.project = project.entries }
        let folders = project.folders + personal.folders
        if folders != self.folders { self.folders = folders }
    }

    /// Every `.md` file in a folder and its subfolders, sorted by folder then title, and the subfolders.
    static func read(_ folder: URL, source: Source) -> (entries: [Entry], folders: [Folder]) {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return ([], []) }
        var entries: [Entry] = []
        var folders: [Folder] = []
        let base = folder.standardizedFileURL.path
        func relative(_ url: URL) -> String {
            let path = url.standardizedFileURL.path
            return path.count > base.count ? String(path.dropFirst(base.count + 1)) : ""
        }
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                folders.append(Folder(source: source, path: relative(url)))
                continue
            }
            guard url.pathExtension.lowercased() == "md",
                  let data = try? Data(contentsOf: url), data.count < 2 << 20 else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let title = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ")
            entries.append(Entry(url: url.standardizedFileURL, source: source,
                                 item: IntelItem.parse(text, fallbackTitle: title), folder: relative(url.deletingLastPathComponent())))
        }
        let sortedEntries = entries.sorted {
            ($0.folder, $0.item.title.localizedLowercase) < ($1.folder, $1.item.title.localizedLowercase)
        }
        // Folder by folder, so a folder's subfolders come right after it.
        let sortedFolders = folders.sorted {
            $0.path.split(separator: "/").map { $0.localizedLowercase }.lexicographicallyPrecedes($1.path.split(separator: "/").map { $0.localizedLowercase })
        }
        return (sortedEntries, sortedFolders)
    }

    func entries(matching query: String) -> [Entry] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return entries }
        return entries.filter { entry in
            [entry.item.title, entry.item.description, entry.item.kind == .script ? entry.item.command : entry.item.body, entry.folder]
                .contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    func entry(at url: URL) -> Entry? {
        entries.first { $0.url == url.standardizedFileURL }
    }

    // MARK: Changing it

    /// Writes an item, in place of `replacing` when given (moving it if the source or folder changed), or
    /// as a new file named after its title. `folder` is where it goes: by default where it already is, or
    /// the top for a new one. Returns where it was written.
    @discardableResult
    func save(_ item: IntelItem, to source: Source, folder path: String? = nil, replacing existing: Entry? = nil) throws -> URL {
        let path = path ?? existing?.folder ?? ""
        guard let folder = url(ofFolder: path, in: source) else { throw CocoaError(.fileNoSuchFile) }
        let manager = FileManager.default
        var url: URL
        if let existing, existing.source == source, existing.folder == path {
            url = existing.url
        } else {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            url = Self.unusedURL(for: IntelItem.fileName(for: item.title), in: folder)
        }
        try Data(item.fileText.utf8).write(to: url, options: .atomic)
        if let existing, existing.url != url { try? manager.removeItem(at: existing.url) }
        changed()
        return url.standardizedFileURL
    }

    /// Moves an item's file into a folder, of either library.
    @discardableResult
    func move(_ entry: Entry, to source: Source, folder path: String) throws -> URL {
        guard entry.source != source || entry.folder != path else { return entry.url }
        guard let folder = url(ofFolder: path, in: source) else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = Self.unusedURL(for: entry.url.lastPathComponent, in: folder)
        try FileManager.default.moveItem(at: entry.url, to: url)
        changed()
        return url.standardizedFileURL
    }

    /// Moves an item's file to the Trash.
    func trash(_ entry: Entry) throws {
        try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
        reload()
    }

    // MARK: Folders

    /// Makes a folder inside `parent`, named `name` or, when that's taken, "name 2" and so on.
    @discardableResult
    func createFolder(named name: String = "New Folder", in source: Source, parent: String = "") throws -> Folder {
        let name = try Self.folderName(name)
        guard let parentURL = url(ofFolder: parent, in: source) else { throw CocoaError(.fileNoSuchFile) }
        let url = Self.unusedFolderURL(for: name, in: parentURL)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        changed()
        return Folder(source: source, path: Self.join(parent, url.lastPathComponent))
    }

    @discardableResult
    func rename(_ folder: Folder, to name: String) throws -> Folder {
        let name = try Self.folderName(name)
        guard name != folder.name else { return folder }
        guard let url = url(ofFolder: folder.path, in: folder.source) else { throw CocoaError(.fileNoSuchFile) }
        let destination = url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        // A change of case only is a rename on a case-insensitive disk, not a clash.
        if FileManager.default.fileExists(atPath: destination.path), name.lowercased() != folder.name.lowercased() {
            throw Failure.exists(name)
        }
        try FileManager.default.moveItem(at: url, to: destination)
        changed()
        return Folder(source: folder.source, path: Self.join(folder.parent, name))
    }

    /// Moves a folder, with all it holds, into another (or to the top, with ""), of either library.
    @discardableResult
    func move(_ folder: Folder, to source: Source, parent: String) throws -> Folder {
        guard !folder.contains(source, parent) else { throw Failure.intoItself }
        guard source != folder.source || parent != folder.parent else { return folder }
        guard let url = url(ofFolder: folder.path, in: folder.source),
              let parentURL = self.url(ofFolder: parent, in: source) else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let destination = Self.unusedFolderURL(for: folder.name, in: parentURL)
        try FileManager.default.moveItem(at: url, to: destination)
        changed()
        return Folder(source: source, path: Self.join(parent, destination.lastPathComponent))
    }

    /// Moves a folder, with all it holds, to the Trash.
    func trash(_ folder: Folder) throws {
        guard let url = url(ofFolder: folder.path, in: folder.source), !folder.path.isEmpty else { return }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        reload()
    }

    /// The name, trimmed, if it can be a folder's.
    static func folderName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":") else { throw Failure.badName }
        return name
    }

    private static func join(_ parent: String, _ name: String) -> String {
        parent.isEmpty ? name : parent + "/" + name
    }

    private func changed() {
        reload()
        // The folder may be new.
        watch()
    }

    static func unusedURL(for name: String, in folder: URL) -> URL {
        let stem = (name as NSString).deletingPathExtension
        var url = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stem)-\(number).md")
            number += 1
        }
        return url
    }

    static func unusedFolderURL(for name: String, in parent: URL) -> URL {
        var url = parent.appendingPathComponent(name, isDirectory: true)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = parent.appendingPathComponent("\(name) \(number)", isDirectory: true)
            number += 1
        }
        return url
    }

    private func watch() {
        guard isActive else { return watchers = [] }
        let folders = [personalFolder] + (projectFolder.map { [$0] } ?? [])
        // FSEvents watches a folder that may not exist yet through its parent.
        watchers = folders.compactMap { folder in
            let existing = FileManager.default.fileExists(atPath: folder.path) ? folder : folder.deletingLastPathComponent()
            return FileWatcher(path: existing.path) { [weak self] _, _ in self?.reload() }
        }
    }
}
