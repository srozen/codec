import AppKit
import Combine
import UniformTypeIdentifiers
import CodecCore

/// A file open in the editor: its text (or what else it is), whether it has unsaved changes, and
/// what's happening to it on disk.
@MainActor
final class EditorDocument: ObservableObject, Identifiable {
    enum Kind: Equatable {
        case text
        case markdown
        case image
        case pdf
        case binary
        /// Not UTF-8: shown read-only.
        case otherEncoding
        case tooLarge(Int)
        case unreadable(String)
    }

    /// How a Markdown file is shown.
    enum Mode: String, CaseIterable {
        case source, split, preview

        var title: String {
            switch self {
            case .source: "Source"
            case .split: "Split"
            case .preview: "Preview"
            }
        }
    }

    let id = UUID()
    let url: URL
    let language: SourceLanguage
    /// The text being edited. The editor view displays and edits this storage directly.
    let storage = NSTextStorage()
    let undoManager = UndoManager()

    @Published private(set) var kind: Kind = .text
    /// A preview tab is replaced by the next file clicked; editing or double-clicking keeps it.
    @Published var isPinned: Bool
    @Published private(set) var isDirty = false
    /// The file changed on disk while there were unsaved edits.
    @Published private(set) var changedOnDisk = false
    /// The file was deleted or moved away.
    @Published private(set) var isMissing = false
    @Published var mode: Mode = .preview
    /// Bumped whenever the text changes, for views that follow it (the Markdown preview).
    @Published private(set) var revision = 0
    private(set) var indentation: Indentation = .spaces(4)
    /// The lines that differ from the last commit, or from the saved file when it isn't in one, for
    /// the marks in the editor's gutter. Not published: it changes as often as the text, and only
    /// the gutter needs it.
    private(set) var lineChanges = LineChanges()
    /// Called when `lineChanges` changes.
    var onLineChanges: (() -> Void)?

    private var savedText = ""
    /// The file as the last commit has it; nil when it isn't committed.
    private var committedText: String?
    private var committedTextTask: Task<Void, Never>?
    private var committedTextPending = false
    private var lineChangesTask: Task<Void, Never>?
    private var lineChangesPending = false
    private var watcher: DispatchSourceFileSystemObject?
    private var isLoading = false

    var name: String { url.lastPathComponent }
    var isEditable: Bool { kind == .text || kind == .markdown }
    var text: String { storage.string }

    init(url: URL, pinned: Bool = false) {
        self.url = url.standardizedFileURL
        self.isPinned = pinned
        language = SourceLanguage.of(fileNamed: url.lastPathComponent)
        load()
        watch()
    }

    deinit {
        watcher?.cancel()
    }

    // MARK: Reading

    static func kind(of url: URL) -> Kind? {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if url.pathExtension.lowercased() == "svg" { return nil }  // SVG is XML: edit it as text.
        if type?.conforms(to: .pdf) == true { return .pdf }
        if type?.conforms(to: .image) == true { return .image }
        return nil
    }

    private func load() {
        if let kind = Self.kind(of: url) {
            self.kind = FileManager.default.isReadableFile(atPath: url.path) ? kind : .unreadable("The file can’t be read.")
            return
        }
        do {
            switch try TextFile.read(url) {
            case .text(let text):
                kind = language == .markdown ? .markdown : .text
                setText(text)
            case .otherEncoding(let text):
                kind = .otherEncoding
                setText(text)
            case .binary:
                kind = .binary
            case .tooLarge(let size):
                kind = .tooLarge(size)
            }
        } catch {
            kind = .unreadable(error.localizedDescription)
        }
    }

    private func setText(_ text: String) {
        isLoading = true
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        isLoading = false
        savedText = text
        indentation = Indentation.detect(in: text)
        isDirty = false
        changedOnDisk = false
        revision += 1
        updateLineChanges()
        // A checkout or a reset changes the file and the commit together.
        refreshCommittedText()
    }

    // MARK: Editing

    /// The editor changed the text.
    func textDidChange() {
        guard !isLoading else { return }
        let dirty = storage.length != (savedText as NSString).length || storage.string != savedText
        if dirty != isDirty { isDirty = dirty }
        if dirty, !isPinned { isPinned = true }
        revision += 1
        updateLineChanges()
    }

    func save() throws {
        guard isEditable else { return }
        let text = storage.string
        try Data(text.utf8).write(to: url, options: .atomic)
        savedText = text
        isDirty = false
        changedOnDisk = false
        isMissing = false
        // An atomic write replaces the file: follow the new one.
        watch()
        updateLineChanges()
    }

    /// Throws away unsaved changes and reads the file again.
    func revert() {
        isMissing = !FileManager.default.fileExists(atPath: url.path)
        guard !isMissing else { return }
        undoManager.removeAllActions()
        load()
        watch()
    }

    // MARK: Changed lines

    /// Reads the last commit's version of the file again, as the lines' changes are measured from
    /// it: when it's opened, and after anything that may have committed (a command, another app).
    func refreshCommittedText() {
        guard isEditable else { return }
        guard committedTextTask == nil else { return committedTextPending = true }
        let repository = GitRepository(directory: url.deletingLastPathComponent())
        let name = url.lastPathComponent
        committedTextTask = Task { [weak self] in
            let text = await repository.committedText(of: name)
            guard let self else { return }
            committedTextTask = nil
            if text != committedText {
                committedText = text
                updateLineChanges()
            }
            if committedTextPending {
                committedTextPending = false
                refreshCommittedText()
            }
        }
    }

    /// Waits for the last commit's version and the changes measured from it, for tests.
    func lineChangesSettled() async {
        while committedTextTask != nil || lineChangesTask != nil {
            await committedTextTask?.value
            await lineChangesTask?.value
        }
    }

    /// Measures the changes again. Small files are measured right away, so a new line's mark
    /// arrives with it; big ones in the background, one measure at a time.
    private func updateLineChanges() {
        guard isEditable else { return setLineChanges(LineChanges()) }
        guard lineChangesTask == nil else { return lineChangesPending = true }
        let old = committedText ?? savedText, new = storage.string
        if storage.length + (old as NSString).length < 50_000 {
            return setLineChanges(LineChanges(from: old, to: new))
        }
        lineChangesTask = Task { [weak self] in
            let changes = await Task.detached(priority: .userInitiated) { LineChanges(from: old, to: new) }.value
            guard let self else { return }
            lineChangesTask = nil
            // Even a measure of an older text is closer than the one shown.
            setLineChanges(changes)
            if lineChangesPending {
                lineChangesPending = false
                updateLineChanges()
            }
        }
    }

    private func setLineChanges(_ changes: LineChanges) {
        guard changes != lineChanges else { return }
        lineChanges = changes
        onLineChanges?()
    }

    // MARK: Watching the disk

    private func watch() {
        watcher?.cancel()
        watcher = nil
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .extend, .delete, .rename, .attrib], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.diskChanged() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    private func diskChanged() {
        let events = watcher?.data ?? []
        if events.contains(.delete) || events.contains(.rename) {
            // Editors save by replacing the file; look for the new one in a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                MainActor.assumeIsolated { self?.fileReplacedOrRemoved() }
            }
            return
        }
        refreshFromDisk()
    }

    private func fileReplacedOrRemoved() {
        guard FileManager.default.fileExists(atPath: url.path) else {
            isMissing = true
            watcher?.cancel()
            watcher = nil
            return
        }
        isMissing = false
        watch()
        refreshFromDisk()
    }

    /// Takes the disk's version unless there are edits to keep; then the user decides.
    private func refreshFromDisk() {
        guard isEditable || kind == .image || kind == .pdf else { return load() }
        if !isEditable {
            revision += 1
            return
        }
        guard case .text(let disk) = (try? TextFile.read(url)) ?? .binary, disk != savedText else { return }
        if isDirty {
            changedOnDisk = true
        } else {
            undoManager.removeAllActions()
            setText(disk)
        }
    }
}

/// The files open in a window's editor, as tabs.
@MainActor
final class EditorModel: ObservableObject {
    @Published private(set) var documents: [EditorDocument] = []
    @Published var selectedID: UUID?

    /// Asks whether to save a document with unsaved changes before closing it. Calls back with true
    /// to go ahead (saved or discarded), false to keep it open.
    var confirmClose: (EditorDocument, @escaping (Bool) -> Void) -> Void = { _, done in done(true) }
    private var observers: Set<AnyCancellable> = []

    init() {
        // A command (a commit, a checkout) or another app may have changed what's committed.
        for name in [Pane.commandDidFinish, NSApplication.didBecomeActiveNotification] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.documents.forEach { $0.refreshCommittedText() } }
                }
                .store(in: &observers)
        }
    }

    var selected: EditorDocument? { documents.first { $0.id == selectedID } }
    var hasUnsavedChanges: Bool { documents.contains(where: \.isDirty) }

    /// Shows `url`. Unpinned, it takes the place of the current preview tab.
    @discardableResult
    func open(_ url: URL, pin: Bool) -> EditorDocument {
        let url = url.standardizedFileURL
        if let existing = documents.first(where: { $0.url == url }) {
            if pin { existing.isPinned = true }
            selectedID = existing.id
            return existing
        }
        let document = EditorDocument(url: url, pinned: pin)
        if !pin, let preview = documents.firstIndex(where: { !$0.isPinned && !$0.isDirty }) {
            documents[preview] = document
        } else if let selected = documents.firstIndex(where: { $0.id == selectedID }) {
            documents.insert(document, at: selected + 1)
        } else {
            documents.append(document)
        }
        selectedID = document.id
        return document
    }

    func close(_ document: EditorDocument, then done: @escaping () -> Void = {}) {
        guard document.isDirty else {
            remove(document)
            return done()
        }
        confirmClose(document) { [weak self] proceed in
            if proceed { self?.remove(document) }
            done()
        }
    }

    private func remove(_ document: EditorDocument) {
        guard let index = documents.firstIndex(where: { $0 === document }) else { return }
        documents.remove(at: index)
        if selectedID == document.id {
            selectedID = documents.isEmpty ? nil : documents[min(index, documents.count - 1)].id
        }
    }

    func select(_ document: EditorDocument) {
        selectedID = document.id
    }

    /// Selects the tab `offset` places away, wrapping around.
    func selectTab(offset: Int) {
        guard let selected, let index = documents.firstIndex(where: { $0 === selected }), !documents.isEmpty else { return }
        selectedID = documents[(index + offset + documents.count) % documents.count].id
    }
}
