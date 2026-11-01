import AppKit
import SwiftUI
import Combine
import CodecCore

/// What the Intel list asks its window to do.
struct IntelActions {
    /// Shows a script's form, to fill in its variables and run or insert it.
    var run: (IntelLibrary.Entry) -> Void = { _ in }
    /// Opens a document in the editor.
    var open: (IntelLibrary.Entry) -> Void = { _ in }
    /// Edits an item's title, description, command and variables.
    var edit: (IntelLibrary.Entry) -> Void = { _ in }
    /// Opens the item's file in the editor, as text.
    var openFile: (IntelLibrary.Entry) -> Void = { _ in }
    /// Starts a new script or document, to save in a library's folder.
    var create: (IntelItem.Kind, IntelLibrary.Source, String) -> Void = { _, _, _ in }
    var focusTerminal: () -> Void = {}
}

/// The Intel tab of the left sidebar: scripts and documents, the project's first, then the user's own,
/// in folders. Click a script to fill in its variables and run it; click a document to read it; drag
/// either into a folder.
final class IntelSidebar: NSView {
    static let collapsedKey = "IntelCollapsedFolders"

    let library: IntelLibrary
    let table = IntelTableView()
    let searchField = NSSearchField()
    var actions = IntelActions()
    /// The user dragged the trailing edge to this width.
    var onResize: ((CGFloat) -> Void)?

    private(set) var rows: [Row] = []
    private let header: NSHostingView<IntelHeader>
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let divider = NSView()
    private let resizeHandle = SidebarResizeHandle()
    private var theme: CodecTheme
    private var cancellables: Set<AnyCancellable> = []
    private let defaults: UserDefaults?
    /// The folders closed, by id.
    private(set) var collapsed: Set<String>
    /// The folder whose name is being edited.
    private(set) var renaming: IntelLibrary.Folder?

    enum Row: Equatable {
        case section(IntelLibrary.Source, String)
        /// A folder, and how many items are in it and its subfolders.
        case folder(IntelLibrary.Folder, count: Int)
        case entry(IntelLibrary.Entry)

        var entry: IntelLibrary.Entry? {
            if case .entry(let entry) = self { return entry }
            return nil
        }

        var folder: IntelLibrary.Folder? {
            if case .folder(let folder, _) = self { return folder }
            return nil
        }

        var id: String {
            switch self {
            case .section(let source, _): "section:\(source)"
            case .folder(let folder, _): "folder:\(folder.id)"
            case .entry(let entry): "entry:\(entry.id)"
            }
        }

        /// Where something dropped or created on this row goes.
        var place: (source: IntelLibrary.Source, folder: String) {
            switch self {
            case .section(let source, _): (source, "")
            case .folder(let folder, _): (folder.source, folder.path)
            case .entry(let entry): (entry.source, entry.folder)
            }
        }
    }

    init(library: IntelLibrary, theme: CodecTheme, defaults: UserDefaults? = nil) {
        self.library = library
        self.theme = theme
        self.defaults = defaults
        collapsed = Set(defaults?.stringArray(forKey: Self.collapsedKey) ?? [])
        header = NSHostingView(rootView: IntelHeader(library: library, create: { _ in }, newFolder: {}, reveal: {}))
        super.init(frame: .zero)
        header.rootView = makeHeader()
        build()
        library.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func makeHeader() -> IntelHeader {
        IntelHeader(library: library,
                    create: { [weak self] kind in
                        guard let self else { return }
                        let place = self.newItemPlace
                        self.actions.create(kind, place.source, place.folder)
                    },
                    newFolder: { [weak self] in
                        guard let self else { return }
                        let place = self.newItemPlace
                        self.newFolder(in: place.source, parent: place.folder)
                    },
                    reveal: { [weak self] in self?.revealPersonalFolder() })
    }

    private func build() {
        wantsLayer = true
        searchField.placeholderString = "Filter Intel"
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 12)
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.setAccessibilityLabel("Filter Intel")

        let column = NSTableColumn(identifier: .init("intel"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.menu = NSMenu()
        table.menu?.delegate = self
        table.menu?.autoenablesItems = false
        table.onPrimaryAction = { [weak self] in self?.activateSelection() }
        table.onExpand = { [weak self] open in self?.expandSelection(open) }
        table.onEscape = { [weak self] in self?.actions.focusTerminal() }
        table.onCopy = { [weak self] in self?.selectedEntry.map { self?.copy($0) } }
        table.onFind = { [weak self] in self?.window?.makeFirstResponder(self?.searchField) }
        table.setAccessibilityLabel("Intel")
        table.registerForDraggedTypes([.intelRow])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.draggingDestinationFeedbackStyle = .sourceList

        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 2, left: 0, bottom: 8, right: 0)

        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor

        divider.wantsLayer = true
        resizeHandle.onDrag = { [weak self] delta in
            guard let self else { return }
            self.onResize?(self.frame.width + delta)
        }

        for view in [header, searchField, scrollView, emptyLabel, divider, resizeHandle] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: divider.leadingAnchor),
            header.heightAnchor.constraint(equalToConstant: 34),
            searchField.topAnchor.constraint(equalTo: header.bottomAnchor),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: divider.leadingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: divider.leadingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 28),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            emptyLabel.trailingAnchor.constraint(equalTo: divider.leadingAnchor, constant: -20),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            resizeHandle.topAnchor.constraint(equalTo: topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: bottomAnchor),
            resizeHandle.centerXAnchor.constraint(equalTo: divider.centerXAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 8),
        ])
        applyTheme(theme)
        reload()
    }

    func applyTheme(_ theme: CodecTheme) {
        self.theme = theme
        header.rootView = makeHeader()
        layer?.backgroundColor = theme.foreground.withAlphaComponent(theme.isDark ? 0.025 : 0.035).cgColor
        divider.layer?.backgroundColor = theme.divider.cgColor
        table.reloadData()
    }

    // MARK: Showing the list

    private var query: String { searchField.stringValue.trimmingCharacters(in: .whitespaces) }

    var selectedEntry: IntelLibrary.Entry? {
        rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].entry : nil
    }

    var selectedFolder: IntelLibrary.Folder? {
        rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].folder : nil
    }

    /// Where + puts a new item or folder: where the selection is, or the top of the user's own.
    private var newItemPlace: (source: IntelLibrary.Source, folder: String) {
        rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].place : (.personal, "")
    }

    func reload() {
        // Not under the name being typed: once it's done.
        guard renaming == nil else { return }
        let selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
        let entries = library.entries(matching: query)
        let searching = !query.isEmpty
        var rows: [Row] = []
        for source in [IntelLibrary.Source.project, .personal] {
            let items = entries.filter { $0.source == source }
            var folders = library.folders(in: source)
            // While filtering, only the folders that lead to a match.
            if searching { folders = folders.filter { folder in items.contains { folder.contains(source, $0.folder) } } }
            guard !items.isEmpty || !folders.isEmpty else { continue }
            let title = source == .personal ? "Personal" : library.projectName.map { "Project · \($0)" } ?? "Project"
            rows.append(.section(source, title))
            func add(_ parent: String) {
                for folder in folders where folder.parent == parent {
                    rows.append(.folder(folder, count: items.count { folder.contains(source, $0.folder) }))
                    if searching || !collapsed.contains(folder.id) { add(folder.path) }
                }
                rows += items.filter { $0.folder == parent }.map(Row.entry)
            }
            add("")
        }
        self.rows = rows
        table.reloadData()
        if let selected, let row = rows.firstIndex(where: { $0.id == selected }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        emptyLabel.isHidden = !rows.isEmpty
        emptyLabel.stringValue = query.isEmpty
            ? "Keep scripts and notes you come back to. Click + to add one, or right-click a command in the Commands sidebar › Save to Intel."
            : "No Intel matches “\(query)”."
    }

    /// Puts the keyboard on the list, on its first item.
    func focusList() {
        if table.selectedRow < 0, let first = rows.firstIndex(where: { $0.entry != nil }) {
            table.selectRowIndexes([first], byExtendingSelection: false)
        }
        window?.makeFirstResponder(table)
    }

    // MARK: Acting on items

    private func entry(at row: Int) -> IntelLibrary.Entry? {
        rows.indices.contains(row) ? rows[row].entry : nil
    }

    @objc private func clicked() {
        guard rows.indices.contains(table.clickedRow) else { return }
        switch rows[table.clickedRow] {
        case .entry(let entry): activate(entry)
        case .folder(let folder, _): toggle(folder)
        case .section: break
        }
    }

    private func activateSelection() {
        if let entry = selectedEntry { activate(entry) } else if let folder = selectedFolder { toggle(folder) }
    }

    // MARK: Folders

    func isExpanded(_ folder: IntelLibrary.Folder) -> Bool {
        !collapsed.contains(folder.id)
    }

    func setExpanded(_ folder: IntelLibrary.Folder, _ expanded: Bool) {
        guard expanded != isExpanded(folder) else { return }
        if expanded { collapsed.remove(folder.id) } else { collapsed.insert(folder.id) }
        defaults?.set(collapsed.sorted(), forKey: Self.collapsedKey)
        reload()
    }

    func toggle(_ folder: IntelLibrary.Folder) {
        setExpanded(folder, !isExpanded(folder))
    }

    /// → opens the selected folder; ← closes it, or goes to the folder the selection is in.
    private func expandSelection(_ open: Bool) {
        if let folder = selectedFolder, open != isExpanded(folder) || !query.isEmpty {
            setExpanded(folder, open)
        } else if !open, rows.indices.contains(table.selectedRow) {
            let place = rows[table.selectedRow]
            let parent = place.folder?.parent ?? place.entry?.folder ?? ""
            guard !parent.isEmpty, let row = rows.firstIndex(where: { $0.folder == .init(source: place.place.source, path: parent) }) else { return }
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
    }

    /// Makes a folder, shows it, and starts naming it.
    func newFolder(in source: IntelLibrary.Source, parent: String) {
        do {
            let folder = try library.createFolder(in: source, parent: parent)
            showFolder(parent, in: source)
            reload()
            guard let row = rows.firstIndex(where: { $0.folder == folder }) else { return }
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
            beginRenaming(folder)
        } catch {
            show(error)
        }
    }

    /// Opens a folder and the ones it's in.
    private func showFolder(_ path: String, in source: IntelLibrary.Source) {
        var path = path
        var changed = false
        while !path.isEmpty {
            changed = collapsed.remove(IntelLibrary.Folder(source: source, path: path).id) != nil || changed
            path = (path as NSString).deletingLastPathComponent
        }
        if changed { defaults?.set(collapsed.sorted(), forKey: Self.collapsedKey) }
    }

    /// Edits a folder's name in its row.
    func beginRenaming(_ folder: IntelLibrary.Folder) {
        guard let row = rows.firstIndex(where: { $0.folder == folder }),
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? IntelFolderCell else { return }
        renaming = folder
        cell.beginEditing { [weak self] name in
            guard let self else { return }
            self.renaming = nil
            self.window?.makeFirstResponder(self.table)
            guard let name else { return self.reload() }
            do {
                let renamed = try self.library.rename(folder, to: name)
                if !self.isExpanded(folder) {
                    self.collapsed.remove(folder.id)
                    self.collapsed.insert(renamed.id)
                }
                self.reload()
                if let row = self.rows.firstIndex(where: { $0.folder == renamed }) {
                    self.table.selectRowIndexes([row], byExtendingSelection: false)
                }
            } catch {
                self.reload()
                self.show(error)
            }
        }
    }

    /// Moves an item or a folder into a folder, or to the top of a library with "".
    func move(_ row: Row, to source: IntelLibrary.Source, folder path: String) throws {
        switch row {
        case .entry(let entry):
            try library.move(entry, to: source, folder: path)
        case .folder(let folder, _):
            let moved = try library.move(folder, to: source, parent: path)
            if !isExpanded(folder) {
                collapsed.remove(folder.id)
                collapsed.insert(moved.id)
            }
        case .section:
            return
        }
        showFolder(path, in: source)
        reload()
    }

    private func show(_ error: any Error) {
        guard let window else { return NSSound.beep() }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    /// Runs a script, or opens a document.
    func activate(_ entry: IntelLibrary.Entry) {
        switch entry.item.kind {
        case .script: actions.run(entry)
        case .doc: actions.open(entry)
        }
    }

    private func copy(_ entry: IntelLibrary.Entry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.item.kind == .script ? entry.item.command : entry.item.body, forType: .string)
    }

    private func revealPersonalFolder() {
        try? FileManager.default.createDirectory(at: library.personalFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([library.personalFolder])
    }

    @objc private func searchChanged() {
        reload()
    }

    private var menuRow: Row? {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        return rows.indices.contains(row) ? rows[row] : nil
    }
}

// MARK: - Data source and delegate

extension IntelSidebar: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .section(_, let title):
            let cell = tableView.makeView(withIdentifier: IntelSectionCell.identifier, owner: nil) as? IntelSectionCell ?? IntelSectionCell()
            cell.show(title)
            return cell
        case .folder(let folder, let count):
            let cell = tableView.makeView(withIdentifier: IntelFolderCell.identifier, owner: nil) as? IntelFolderCell ?? IntelFolderCell()
            cell.show(folder, count: count, expanded: !query.isEmpty || isExpanded(folder), theme: theme)
            return cell
        case .entry(let entry):
            let cell = tableView.makeView(withIdentifier: IntelCell.identifier, owner: nil) as? IntelCell ?? IntelCell()
            cell.show(entry, theme: theme)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .section: 24
        case .folder: 24
        case .entry(let entry): entry.item.description.isEmpty ? 26 : 40
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .section = rows[row] { return false }
        return true
    }

    // MARK: Dragging into folders

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        let url: URL?
        switch rows[row] {
        case .section: return nil
        case .folder(let folder, _): url = library.url(ofFolder: folder.path, in: folder.source)
        case .entry(let entry): url = entry.url
        }
        let item = NSPasteboardItem()
        item.setString(rows[row].id, forType: .intelRow)
        // Out of the list, it's the file: to Finder, or the terminal.
        if let url { item.setString(url.absoluteString, forType: .fileURL) }
        return item
    }

    /// The row being dragged, from this list.
    private func draggedRow(_ info: any NSDraggingInfo) -> Row? {
        guard (info.draggingSource as? NSTableView) === table,
              let id = info.draggingPasteboard.string(forType: .intelRow) else { return nil }
        return rows.first { $0.id == id }
    }

    /// The row a drop lands on: the folder or section it goes into.
    func dropTarget(row: Int, operation: NSTableView.DropOperation) -> Int? {
        guard !rows.isEmpty else { return nil }
        let row = min(row, rows.count - 1)
        // On a folder or a section, into it; above a folder, or on or above an item, into what holds it.
        if operation == .on, rows[row].entry == nil { return row }
        let place: (source: IntelLibrary.Source, folder: String)
        if operation == .above, row == rows.count - 1, rows[row].entry == nil, rows.count > 1 {
            place = rows[row].place
        } else if let folder = rows[row].folder {
            place = (folder.source, folder.parent)
        } else if case .section = rows[row], row > 0 {
            // Above a section: the end of the one before.
            place = rows[row - 1].place
        } else {
            place = rows[row].place
        }
        return rows.firstIndex { candidate in
            switch candidate {
            case .section(let source, _): place.folder.isEmpty && source == place.source
            case .folder(let folder, _): folder.source == place.source && folder.path == place.folder
            case .entry: false
            }
        }
    }

    private func canMove(_ dragged: Row, to place: (source: IntelLibrary.Source, folder: String)) -> Bool {
        guard library.folder(for: place.source) != nil else { return false }
        switch dragged {
        case .entry(let entry): return entry.source != place.source || entry.folder != place.folder
        case .folder(let folder, _):
            return !folder.contains(place.source, place.folder) && (folder.source != place.source || folder.parent != place.folder)
        case .section: return false
        }
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard let dragged = draggedRow(info), let target = dropTarget(row: row, operation: operation),
              canMove(dragged, to: rows[target].place) else { return [] }
        tableView.setDropRow(target, dropOperation: .on)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let dragged = draggedRow(info), let target = dropTarget(row: row, operation: dropOperation) else { return false }
        let place = rows[target].place
        guard canMove(dragged, to: place) else { return false }
        do {
            try move(dragged, to: place.source, folder: place.folder)
            return true
        } catch {
            show(error)
            return false
        }
    }
}

extension NSPasteboard.PasteboardType {
    /// A row of the Intel list, dragged within it.
    static let intelRow = NSPasteboard.PasteboardType("com.codec.intel-row")
}

// MARK: - Filter field

extension IntelSidebar: NSSearchFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            focusList()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if let first = rows.first(where: { $0.entry != nil })?.entry { activate(first) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if query.isEmpty {
                actions.focusTerminal()
            } else {
                searchField.stringValue = ""
                reload()
            }
            return true
        default:
            return false
        }
    }
}

// MARK: - Context menu

extension IntelSidebar: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        switch menuRow {
        case .entry(let entry): contextMenuItems(for: entry).forEach(menu.addItem)
        case .folder(let folder, _): contextMenuItems(for: folder).forEach(menu.addItem)
        case .section(let source, _): contextMenuItems(forTopOf: source).forEach(menu.addItem)
        case nil: break
        }
    }

    private func otherSourceTitle(_ other: IntelLibrary.Source) -> String {
        other == .personal ? "Move to Personal" : "Move to Project" + (library.projectName.map { " (\($0))" } ?? "")
    }

    /// New Script, New Document and New Folder, in a place.
    private func creationItems(_ source: IntelLibrary.Source, _ folder: String, here: Bool) -> [NSMenuItem] {
        let suffix = here ? " Here" : ""
        return [
            ClosureMenuItem("New Script\(suffix)…", image: "apple.terminal") { [weak self] in self?.actions.create(.script, source, folder) },
            ClosureMenuItem("New Document\(suffix)…", image: "doc.text") { [weak self] in self?.actions.create(.doc, source, folder) },
            ClosureMenuItem("New Folder", image: "folder.badge.plus") { [weak self] in self?.newFolder(in: source, parent: folder) },
        ]
    }

    func contextMenuItems(for folder: IntelLibrary.Folder) -> [NSMenuItem] {
        var items = creationItems(folder.source, folder.path, here: true)
        items.append(.separator())
        items.append(ClosureMenuItem("Rename", image: "pencil") { [weak self] in self?.beginRenaming(folder) })
        let other: IntelLibrary.Source = folder.source == .personal ? .project : .personal
        items.append(ClosureMenuItem(otherSourceTitle(other), image: "arrow.left.arrow.right",
                                     enabled: library.folder(for: other) != nil) { [weak self] in
            do { try self?.move(.folder(folder, count: 0), to: other, folder: "") } catch { self?.show(error) }
        })
        if !folder.parent.isEmpty {
            items.append(ClosureMenuItem("Move Out of “\((folder.parent as NSString).lastPathComponent)”", image: "arrow.up.left") { [weak self] in
                do { try self?.move(.folder(folder, count: 0), to: folder.source, folder: (folder.parent as NSString).deletingLastPathComponent) }
                catch { self?.show(error) }
            })
        }
        items.append(.separator())
        let url = library.url(ofFolder: folder.path, in: folder.source)
        items.append(ClosureMenuItem("Reveal in Finder", image: "folder") {
            url.map { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        })
        items.append(ClosureMenuItem("Move to Trash", image: "trash") { [weak self] in
            do { try self?.library.trash(folder) } catch { self?.show(error) }
        })
        return items
    }

    func contextMenuItems(forTopOf source: IntelLibrary.Source) -> [NSMenuItem] {
        var items = creationItems(source, "", here: false)
        items.append(.separator())
        let url = library.folder(for: source)
        items.append(ClosureMenuItem("Reveal in Finder", image: "folder") {
            guard let url else { return }
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        })
        return items
    }

    func contextMenuItems(for entry: IntelLibrary.Entry) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        switch entry.item.kind {
        case .script:
            items.append(ClosureMenuItem("Run…", image: "play") { [weak self] in self?.actions.run(entry) })
            items.append(ClosureMenuItem("Copy Command", image: "doc.on.doc") { [weak self] in self?.copy(entry) })
        case .doc:
            items.append(ClosureMenuItem("Open", image: "doc.richtext") { [weak self] in self?.actions.open(entry) })
        }
        items.append(.separator())
        items.append(ClosureMenuItem("Edit…", image: "pencil") { [weak self] in self?.actions.edit(entry) })
        items.append(ClosureMenuItem("Open File", image: "doc.text") { [weak self] in self?.actions.openFile(entry) })
        let other: IntelLibrary.Source = entry.source == .personal ? .project : .personal
        items.append(ClosureMenuItem(otherSourceTitle(other), image: "arrow.left.arrow.right", enabled: library.folder(for: other) != nil) { [weak self] in
            do { try self?.move(.entry(entry), to: other, folder: entry.folder) } catch { self?.show(error) }
        })
        if !entry.folder.isEmpty {
            items.append(ClosureMenuItem("Move Out of “\((entry.folder as NSString).lastPathComponent)”", image: "arrow.up.left") { [weak self] in
                do { try self?.move(.entry(entry), to: entry.source, folder: (entry.folder as NSString).deletingLastPathComponent) }
                catch { self?.show(error) }
            })
        }
        items.append(.separator())
        items.append(ClosureMenuItem("Reveal in Finder", image: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        })
        items.append(ClosureMenuItem("Move to Trash", image: "trash") { [weak self] in
            do { try self?.library.trash(entry) } catch { NSSound.beep() }
        })
        return items
    }
}

// MARK: - Header

/// "Intel", and buttons to add to it and find its folder.
struct IntelHeader: View {
    @ObservedObject var library: IntelLibrary
    var create: (IntelItem.Kind) -> Void
    var newFolder: () -> Void
    var reveal: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("Intel")
                .font(.system(size: 12, weight: .semibold))
            if let project = library.projectName {
                Text(project)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Menu {
                Button("New Script…", systemImage: "terminal") { create(.script) }
                Button("New Document…", systemImage: "doc.text") { create(.doc) }
                Divider()
                Button("New Folder", systemImage: "folder.badge.plus") { newFolder() }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 24, height: 24)
            .foregroundStyle(.secondary)
            .help("New Script, Document or Folder")
            .accessibilityLabel("New Script, Document or Folder")
            Button(action: reveal) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Show Your Intel Folder in Finder")
            .accessibilityLabel("Show Your Intel Folder in Finder")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Views

/// The list, with Return, Escape, ⌘C and ⌘F.
final class IntelTableView: NSTableView {
    var onPrimaryAction: (() -> Void)?
    /// → (true) and ← (false).
    var onExpand: ((Bool) -> Void)?
    var onEscape: (() -> Void)?
    var onCopy: (() -> Void)?
    var onFind: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onPrimaryAction?()
        case 123: onExpand?(false)
        case 124: onExpand?(true)
        case 53: onEscape?()
        default: super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) { onCopy?() }

    override func performTextFinderAction(_ sender: Any?) { onFind?() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): selectedRow >= 0
        case #selector(performTextFinderAction(_:)): true
        default: super.validateUserInterfaceItem(item)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        return super.menu(for: event)
    }
}

final class IntelSectionCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("IntelSectionCell")
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ title: String) {
        label.stringValue = title
    }
}

/// One item: a terminal glyph for scripts or a page for documents, the title, and its description.
final class IntelCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("IntelCell")

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var titleCenter: NSLayoutConstraint!
    private var titleTop: NSLayoutConstraint!
    private var indent: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        title.font = .systemFont(ofSize: 12.5, weight: .medium)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        for label in [title, detail] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for view in [icon, title, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        titleCenter = title.centerYAnchor.constraint(equalTo: centerYAnchor)
        titleTop = title.topAnchor.constraint(equalTo: topAnchor, constant: 4)
        indent = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: IntelFolderCell.inset(depth: 0) + IntelFolderCell.chevronWidth)
        NSLayoutConstraint.activate([
            indent,
            icon.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ entry: IntelLibrary.Entry, theme: CodecTheme) {
        let script = entry.item.kind == .script
        icon.image = NSImage(systemSymbolName: script ? "apple.terminal" : "doc.text", accessibilityDescription: script ? "Script" : "Document")
        icon.contentTintColor = script ? theme.accent : .secondaryLabelColor
        title.stringValue = entry.item.title
        indent.constant = IntelFolderCell.inset(depth: entry.folder.split(separator: "/").count) + IntelFolderCell.chevronWidth
        let hasDetail = !entry.item.description.isEmpty
        detail.stringValue = entry.item.description
        detail.isHidden = !hasDetail
        titleTop.isActive = hasDetail
        titleCenter.isActive = !hasDetail
        toolTip = script ? entry.item.command : entry.item.description
        setAccessibilityLabel("\(entry.item.title), \(script ? "script" : "document")")
    }
}

/// A folder: a disclosure chevron, its icon, its name, and how many items it holds.
final class IntelFolderCell: NSTableCellView, NSTextFieldDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("IntelFolderCell")
    static let chevronWidth: CGFloat = 13

    /// Where a row's chevron starts, for an item or folder this deep.
    static func inset(depth: Int) -> CGFloat { 2 + CGFloat(depth) * 14 }

    private let chevron = NSImageView()
    private let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private var indent: NSLayoutConstraint!
    private var onEndEditing: ((String?) -> Void)?
    private var nameBeforeEditing = ""

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        chevron.contentTintColor = .tertiaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        name.font = .systemFont(ofSize: 12.5, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.maximumNumberOfLines = 1
        name.cell?.isScrollable = true
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.delegate = self
        count.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        count.textColor = .tertiaryLabelColor
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [chevron, icon, name, count] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        indent = chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset(depth: 0))
        NSLayoutConstraint.activate([
            indent,
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: Self.chevronWidth),
            icon.leadingAnchor.constraint(equalTo: chevron.trailingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ folder: IntelLibrary.Folder, count: Int, expanded: Bool, theme: CodecTheme) {
        if onEndEditing != nil { finishEditing(nil) }
        indent.constant = Self.inset(depth: folder.depth - 1)
        chevron.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")
        name.stringValue = folder.name
        self.count.stringValue = count > 0 ? "\(count)" : ""
        toolTip = folder.path
        setAccessibilityLabel("\(folder.name), folder, \(count) \(count == 1 ? "item" : "items"), \(expanded ? "expanded" : "collapsed")")
    }

    // MARK: Renaming

    var isEditing: Bool { onEndEditing != nil }

    /// Makes the name editable; `done` gets the new name, or nil if the user cancelled.
    func beginEditing(_ done: @escaping (String?) -> Void) {
        onEndEditing = done
        nameBeforeEditing = name.stringValue
        name.isEditable = true
        name.isBezeled = true
        name.bezelStyle = .roundedBezel
        name.drawsBackground = true
        window?.makeFirstResponder(name)
        name.currentEditor()?.selectAll(nil)
    }

    func finishEditing(_ newName: String?) {
        guard let done = onEndEditing else { return }
        onEndEditing = nil
        name.isEditable = false
        name.isBezeled = false
        name.drawsBackground = false
        if newName == nil { name.stringValue = nameBeforeEditing }
        done(newName == nameBeforeEditing ? nil : newName)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            finishEditing(name.stringValue)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finishEditing(nil)
            return true
        default:
            return false
        }
    }

    /// Clicking elsewhere keeps the name typed.
    func controlTextDidEndEditing(_ notification: Notification) {
        finishEditing(name.stringValue)
    }
}

// MARK: - Files and Intel

/// Which tab the left sidebar shows.
enum NavigatorTab: String {
    case files, intel
}

/// The tabs above the left sidebar: Files and Intel.
struct NavigatorBar: View {
    @ObservedObject var model: WindowModel
    let theme: CodecTheme
    var select: (NavigatorTab) -> Void

    var body: some View {
        HStack(spacing: 2) {
            tab(.files, title: "Files", systemImage: "folder", shortcut: "⇧⌘E")
            tab(.intel, title: "Intel", systemImage: "antenna.radiowaves.left.and.right", shortcut: "⇧⌘I")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.dividerColor).frame(height: 1) }
    }

    private func tab(_ tab: NavigatorTab, title: String, systemImage: String, shortcut: String) -> some View {
        let selected = model.navigatorTab == tab
        return Button { select(tab) } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(selected ? 0.09 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? .primary : .secondary)
        .help("\(title) (\(shortcut))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
