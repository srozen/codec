import AppKit
import CoreServices
import CodecCore

/// A file or folder shown in the file tree. A class, so the outline view keeps track of the same
/// item (its expansion and selection) across reloads.
@MainActor
final class FileNode: NSObject {
    let url: URL
    let name: String
    let isDirectory: Bool
    /// Relative to the tree's root, as git names it. Empty for the root itself.
    let relativePath: String
    /// Nil until the folder is first opened.
    fileprivate(set) var children: [FileNode]?

    init(url: URL, name: String, isDirectory: Bool, relativePath: String) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.relativePath = relativePath
    }
}

/// The file tree of the window's focused pane: the repository it's in, or its directory outside
/// one. Folders load as they're opened and reload when their files change on disk.
@MainActor
final class FileTreeModel: ObservableObject {
    @Published private(set) var root: FileNode?
    /// The focused pane's directory, highlighted in the tree.
    @Published private(set) var currentDirectory: URL?
    @Published private(set) var status = GitStatus()
    @Published private(set) var isRepository = false
    @Published var showHidden: Bool {
        didSet {
            defaults.set(showHidden, forKey: Self.showHiddenKey)
            reloadAll()
        }
    }
    /// Filters the tree by file name across the whole root.
    @Published var query = "" {
        didSet { updateResults() }
    }
    @Published private(set) var results: [FileNode] = []

    /// Called after folders' contents changed (nil: everything), so the outline can reload them.
    var onReload: ((Set<FileNode>?) -> Void)?
    /// Called to open the folders down to the current directory.
    var onReveal: ((URL) -> Void)?

    /// The tree only watches the disk and runs git while it's on screen.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if isActive {
                startWatching()
                reloadAll()
                refreshStatus()
            } else {
                watcher = nil
            }
        }
    }

    private static let showHiddenKey = "FileTreeShowsHiddenFiles"
    /// Every node made so far, by standardized path.
    private var nodes: [String: FileNode] = [:]
    private var watcher: FileWatcher?
    private var statusTask: Task<Void, Never>?
    private var statusPending = false
    private var searchCandidates: [String]?
    private var searchTask: Task<Void, Never>?
    private let runner: any GitRunning
    private let defaults: UserDefaults

    init(defaults: UserDefaults, runner: any GitRunning = ProcessGitRunner()) {
        self.defaults = defaults
        self.runner = runner
        showHidden = defaults.bool(forKey: Self.showHiddenKey)
    }

    // MARK: Following the focused pane

    /// Shows the tree for `directory`: its repository's root, or `directory` itself outside one.
    func follow(_ directory: String) {
        guard !directory.isEmpty else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        let repository = GitInfo.workTreeRoot(containing: url)
        let rootURL = (repository ?? url).standardizedFileURL
        if root?.url.path != rootURL.path {
            nodes = [:]
            root = nil
            searchCandidates = nil
            status = GitStatus()
            isRepository = repository != nil
            root = node(for: rootURL, isDirectory: true)
            if isActive {
                startWatching()
                refreshStatus()
            }
            onReload?(nil)
            updateResults()
        }
        currentDirectory = url
        if isActive { onReveal?(url) }
    }

    private func node(for url: URL, name: String? = nil, isDirectory: Bool) -> FileNode {
        if let existing = nodes[url.path], existing.isDirectory == isDirectory { return existing }
        let rootPath = root?.url.path ?? url.path
        let relative = url.path == rootPath ? "" : String(url.path.dropFirst(rootPath.count + 1))
        let node = FileNode(url: url, name: name ?? url.lastPathComponent, isDirectory: isDirectory, relativePath: relative)
        nodes[url.path] = node
        return node
    }

    func node(at url: URL) -> FileNode? { nodes[url.standardizedFileURL.path] }

    // MARK: Contents

    /// A folder's contents, read the first time they're asked for.
    func children(of folder: FileNode) -> [FileNode] {
        if let children = folder.children { return children }
        load(folder)
        return folder.children ?? []
    }

    private func load(_ folder: FileNode) {
        folder.children = FileListing.entries(in: folder.url, showHidden: showHidden).map {
            node(for: $0.url.standardizedFileURL, name: $0.name, isDirectory: $0.isDirectory)
        }
    }

    /// Rereads folders that were already opened.
    func reload(_ folders: Set<FileNode>) {
        let loaded = folders.filter { $0.children != nil }
        guard !loaded.isEmpty else { return }
        loaded.forEach(load)
        onReload?(loaded)
    }

    func reloadAll() {
        nodes.values.filter { $0.children != nil }.forEach(load)
        searchCandidates = nil
        onReload?(nil)
        updateResults()
    }

    /// The disk changed under these paths.
    private func filesChanged(_ paths: [String], rescan: Bool) {
        refreshStatusSoon()
        searchCandidates = nil
        if rescan { return reloadAll() }
        let folders = paths.compactMap { path -> FileNode? in
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            // Inside .git only the status changes.
            guard !url.pathComponents.contains(".git") else { return nil }
            return nodes[url.path]
        }
        reload(Set(folders))
        if !query.isEmpty { updateResults() }
    }

    // MARK: Git status

    private var statusTimer: Timer?

    private func refreshStatusSoon() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
    }

    /// Asks git what changed. One run at a time; a request during a run starts another after it.
    func refreshStatus() {
        guard isRepository, let root else {
            if !status.isEmpty { status = GitStatus() }
            return
        }
        guard statusTask == nil else {
            statusPending = true
            return
        }
        let repository = GitRepository(directory: root.url, runner: runner)
        statusTask = Task { [weak self] in
            let status = (try? await repository.status()) ?? GitStatus()
            guard let self else { return }
            if self.root === root, status != self.status { self.status = status }
            self.statusTask = nil
            if self.statusPending {
                self.statusPending = false
                self.refreshStatus()
            }
        }
    }

    /// Waits for the current git run, for tests.
    func statusSettled() async {
        while let task = statusTask { await task.value }
    }

    // MARK: Search

    private func updateResults() {
        searchTask?.cancel()
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let root else {
            if !results.isEmpty { results = [] }
            return
        }
        if let candidates = searchCandidates {
            showResults(FileListing.search(candidates, for: query), under: root)
            return
        }
        let repository = isRepository ? GitRepository(directory: root.url, runner: runner) : nil
        let rootURL = root.url
        searchTask = Task { [weak self] in
            var candidates: [String]
            if let repository, let files = try? await repository.files() {
                candidates = files
            } else {
                candidates = await Task.detached(priority: .userInitiated) {
                    FileListing.searchCandidates(under: rootURL)
                }.value
            }
            if !(self?.showHidden ?? false) {
                candidates = candidates.filter { !$0.split(separator: "/").contains { $0.hasPrefix(".") } }
            }
            guard let self, !Task.isCancelled, self.root === root else { return }
            self.searchCandidates = candidates
            self.searchTask = nil
            self.updateResults()
        }
    }

    private func showResults(_ paths: [String], under root: FileNode) {
        results = paths.map { path in
            let url = root.url.appendingPathComponent(path).standardizedFileURL
            return nodes[url.path] ?? FileNode(url: url, name: url.lastPathComponent, isDirectory: false, relativePath: path)
        }
    }

    /// Waits for the search candidates to load, for tests.
    func searchSettled() async {
        await searchTask?.value
    }

    // MARK: Watching

    private func startWatching() {
        guard let root else { return watcher = nil }
        watcher = FileWatcher(path: root.url.path) { [weak self] paths, rescan in
            self?.filesChanged(paths, rescan: rescan)
        }
    }
}

/// Reports changes anywhere below a folder, through FSEvents, on the main queue.
@MainActor
final class FileWatcher {
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    private let handler: @MainActor (_ folders: [String], _ rescan: Bool) -> Void

    init?(path: String, latency: TimeInterval = 0.2, handler: @escaping @MainActor ([String], Bool) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let rescan = (0..<count).contains { flags[$0] & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 }
            MainActor.assumeIsolated { watcher.handler(list, rescan) }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
