import Foundation

/// A file or folder in the file tree.
public struct FileEntry: Hashable, Sendable {
    public let url: URL
    public let name: String
    /// A folder that can be opened in the tree. Packages such as apps are files, as in Finder.
    public let isDirectory: Bool

    public init(url: URL, name: String? = nil, isDirectory: Bool) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.isDirectory = isDirectory
    }
}

/// Reads folders for the file tree.
public enum FileListing {
    /// Never shown: git's own folder and Finder's litter.
    static let alwaysHidden: Set<String> = [".git", ".DS_Store"]
    /// Skipped when searching outside a repository, where there's no .gitignore to say so.
    static let heavyFolders: Set<String> = ["node_modules", ".build", "build", "DerivedData", "Pods", "target", "dist", "__pycache__", ".venv", "venv"]

    /// A folder's contents, folders first, each group in Finder's order ("file2" before "file10").
    public static func entries(in directory: URL, showHidden: Bool, fileManager: FileManager = .default) -> [FileEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey]
        guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return [] }
        let entries = urls.compactMap { url -> FileEntry? in
            let name = url.lastPathComponent
            guard !alwaysHidden.contains(name) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if !showHidden, name.hasPrefix(".") || values?.isHidden == true { return nil }
            var isDirectory = values?.isDirectory == true && values?.isPackage != true
            if values?.isSymbolicLink == true {
                var target: ObjCBool = false
                isDirectory = fileManager.fileExists(atPath: url.path, isDirectory: &target) && target.boolValue
            }
            return FileEntry(url: url, name: name, isDirectory: isDirectory)
        }
        return entries.sorted { lhs, rhs in
            lhs.isDirectory != rhs.isDirectory ? lhs.isDirectory : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Files under `root` to search by name when git can't list them, relative to `root`. Hidden
    /// files, packages and dependency folders are skipped, and the walk stops at `limit` files.
    public static func searchCandidates(under root: URL, limit: Int = 20_000, fileManager: FileManager = .default) -> [String] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: keys,
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let base = root.standardizedFileURL.path
        var files: [String] = []
        while files.count < limit, let url = walker.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true, values?.isPackage != true {
                if heavyFolders.contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            files.append(String(path.dropFirst(base.count + 1)))
        }
        return files
    }

    /// Paths best matching `query`, best first: a match in the file name beats one in the folders above it.
    public static func search(_ paths: [String], for query: String, limit: Int = 200) -> [String] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let scored = paths.compactMap { path -> (String, Int)? in
            let name = path.split(separator: "/").last.map(String.init) ?? path
            let byName = FuzzyMatch.score(query, in: name).map { $0 + 10_000 }
            let score = max(byName ?? .min, FuzzyMatch.score(query, in: path) ?? .min)
            guard score != .min else { return nil }
            return (path, score)
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(limit).map(\.0)
    }
}

/// What `git status` says about the files in a working tree.
public struct GitStatus: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case modified, added, deleted, renamed, untracked, conflicted, ignored

        /// The letter shown next to the file, as in most editors.
        public var badge: String {
            switch self {
            case .modified: "M"
            case .added: "A"
            case .deleted: "D"
            case .renamed: "R"
            case .untracked: "U"
            case .conflicted: "!"
            case .ignored: ""
            }
        }
    }

    private var files: [String: Kind] = [:]
    /// Folders git reports as a whole ("?? new-folder/", "!! node_modules/"), without the slash.
    private var folders: [String: Kind] = [:]
    /// Folders holding a change somewhere below them.
    private var changedFolders: Set<String> = []

    public init() {}

    /// Reads `git status --porcelain=v1 -z` output.
    public init(porcelain: String) {
        var fields = porcelain.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let field = fields.next() {
            guard field.count > 3 else { continue }
            let code = Array(field.prefix(2))
            var path = String(field.dropFirst(3))
            // A rename or copy is followed by the old path.
            if code.contains("R") || code.contains("C") { _ = fields.next() }
            let kind = Self.kind(x: code[0], y: code[1])
            if path.hasSuffix("/") {
                path.removeLast()
                folders[path] = kind
            } else {
                files[path] = kind
            }
            if kind != .ignored { markAncestors(of: path) }
        }
    }

    private static func kind(x: Character, y: Character) -> Kind {
        switch (x, y) {
        case ("?", "?"): .untracked
        case ("!", "!"): .ignored
        case ("U", _), (_, "U"), ("A", "A"), ("D", "D"): .conflicted
        case ("A", _): .added
        case ("R", _), ("C", _): .renamed
        case ("D", _), (_, "D"): .deleted
        default: .modified
        }
    }

    private mutating func markAncestors(of path: String) {
        var parts = path.split(separator: "/").dropLast()
        while !parts.isEmpty {
            changedFolders.insert(parts.joined(separator: "/"))
            parts = parts.dropLast()
        }
    }

    /// The status of a file or folder, relative to the root. Things inside an untracked or ignored
    /// folder are untracked or ignored too.
    public func kind(of path: String) -> Kind? {
        if let kind = files[path] ?? folders[path] { return kind }
        var parts = path.split(separator: "/").dropLast()
        while !parts.isEmpty {
            if let kind = folders[parts.joined(separator: "/")] { return kind }
            parts = parts.dropLast()
        }
        return nil
    }

    /// Whether something below a folder (relative to the root) changed.
    public func containsChanges(_ folder: String) -> Bool {
        changedFolders.contains(folder)
    }

    public var isEmpty: Bool { files.isEmpty && folders.isEmpty }
}

public enum ShellQuoting {
    /// `text` as one shell word: as is when that's safe, otherwise in single quotes.
    public static func quote(_ text: String) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./~+:@%,=")
        if !text.isEmpty, text.allSatisfy(safe.contains), !text.hasPrefix("~") { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
