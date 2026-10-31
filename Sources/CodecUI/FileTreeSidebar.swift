import AppKit
import SwiftUI
import Combine
import CodecCore

/// What the file tree asks its window to do.
struct FileTreeActions {
    /// Shows a file in Codec's editor as a preview tab, which the next one replaces.
    var preview: (URL) -> Void = { _ in }
    /// Opens a file in Codec's editor, in a tab of its own.
    var open: (URL) -> Void = { _ in }
    var openInDefaultApp: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Opens a file in `$EDITOR`, in a new pane.
    var openInEditor: (URL) -> Void = { _ in }
    /// `cd`s the focused pane into a folder.
    var changeDirectory: (URL) -> Void = { _ in }
    var openInNewTab: (URL) -> Void = { _ in }
    /// Types paths on the focused pane's command line.
    var insertPaths: ([URL]) -> Void = { _ in }
    /// Gives the keyboard back to the terminal.
    var focusTerminal: () -> Void = {}
}

/// The file tree on the left of the window: a header, a filter field and the outline.
final class FileTreeSidebar: NSView {
    static let defaultWidth: CGFloat = 250
    static let widthRange: ClosedRange<CGFloat> = 160...520

    let model: FileTreeModel
    let outline = FileOutlineView()
    let searchField = NSSearchField()
    var actions = FileTreeActions()
    /// The user dragged the trailing edge to this width.
    var onResize: ((CGFloat) -> Void)?

    private let header: NSHostingView<FileTreeHeader>
    private let scrollView = NSScrollView()
    private let divider = NSView()
    private let resizeHandle = SidebarResizeHandle()
    private var theme: CodecTheme
    private var cancellables: Set<AnyCancellable> = []

    init(model: FileTreeModel, theme: CodecTheme) {
        self.model = model
        self.theme = theme
        header = NSHostingView(rootView: FileTreeHeader(model: model, theme: theme, collapseAll: {}))
        super.init(frame: .zero)
        header.rootView = FileTreeHeader(model: model, theme: theme, collapseAll: { [weak self] in self?.collapseAll() })
        build()
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func build() {
        wantsLayer = true
        searchField.placeholderString = "Filter files"
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 12)
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.setAccessibilityLabel("Filter files")

        let column = NSTableColumn(identifier: .init("file"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.rowHeight = 22
        outline.indentationPerLevel = 12
        outline.allowsMultipleSelection = true
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.doubleAction = #selector(doubleClicked)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.setDraggingSourceOperationMask(.copy, forLocal: true)
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.onPrimaryAction = { [weak self] in self?.performPrimaryAction(on: self?.outline.selectedNodes ?? []) }
        outline.onEscape = { [weak self] in self?.actions.focusTerminal() }
        outline.onCopy = { [weak self] in self?.copyPaths(self?.outline.selectedNodes ?? [], relative: false) }
        outline.setAccessibilityLabel("Files")

        scrollView.documentView = outline
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 2, left: 0, bottom: 8, right: 0)

        divider.wantsLayer = true
        resizeHandle.onDrag = { [weak self] delta in
            guard let self else { return }
            self.onResize?(self.frame.width + delta)
        }

        for view in [header, searchField, scrollView, divider, resizeHandle] as [NSView] {
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
    }

    private func observe() {
        model.onReload = { [weak self] folders in self?.reload(folders) }
        model.onReveal = { [weak self] url in self?.reveal(url) }
        // Status and the current directory only change how rows look.
        model.$status.combineLatest(model.$currentDirectory)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshVisibleRows() } }
            .store(in: &cancellables)
        model.$results
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.model.query.isEmpty else { return }
                    self.outline.reloadData()
                    if self.outline.numberOfRows > 0 { self.outline.selectRowIndexes([0], byExtendingSelection: false) }
                }
            }
            .store(in: &cancellables)
    }

    func applyTheme(_ theme: CodecTheme) {
        self.theme = theme
        header.rootView = FileTreeHeader(model: model, theme: theme, collapseAll: { [weak self] in self?.collapseAll() })
        layer?.backgroundColor = theme.foreground.withAlphaComponent(theme.isDark ? 0.025 : 0.035).cgColor
        divider.layer?.backgroundColor = theme.divider.cgColor
        refreshVisibleRows()
    }

    // MARK: Showing the tree

    private var isSearching: Bool { !model.query.trimmingCharacters(in: .whitespaces).isEmpty }

    private func reload(_ folders: Set<FileNode>?) {
        guard !isSearching else { return }
        guard let folders else { return outline.reloadData() }
        for folder in folders {
            outline.reloadItem(folder === model.root ? nil : folder, reloadChildren: true)
        }
    }

    private func refreshVisibleRows() {
        let rows = outline.rows(in: outline.visibleRect)
        guard rows.length > 0 else { return }
        for row in rows.location..<(rows.location + rows.length) {
            guard let node = outline.item(atRow: row) as? FileNode,
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCell else { continue }
            configure(cell, for: node)
        }
    }

    /// Opens the folders down to `url`, and `url` itself, and scrolls it into view.
    func reveal(_ url: URL) {
        guard !isSearching, let root = model.root, url.path.hasPrefix(root.url.path) else { return }
        var folder = root
        var target: FileNode?
        for component in url.pathComponents.dropFirst(root.url.pathComponents.count) {
            guard let next = model.children(of: folder).first(where: { $0.name == component && $0.isDirectory }) else { break }
            outline.expandItem(folder === root ? nil : folder)
            folder = next
            target = next
        }
        if let target {
            outline.expandItem(target)
            let row = outline.row(forItem: target)
            if row >= 0 { outline.scrollRowToVisible(row) }
        }
    }

    func collapseAll() {
        outline.collapseItem(nil, collapseChildren: true)
        if let root = model.root {
            for child in model.children(of: root) { outline.collapseItem(child, collapseChildren: true) }
        }
    }

    private func configure(_ cell: FileCell, for node: FileNode) {
        let kind = model.status.kind(of: node.relativePath)
        let current = node.isDirectory && node.url.path == model.currentDirectory?.path
        let color: NSColor = kind.map(theme.color(for:)) ?? .labelColor
        let icon = node.isDirectory
            ? FileIcons.image(for: FolderType.of(folderNamed: node.name),
                              state: current ? .current : outline.isItemExpanded(node) ? .open : .closed, theme: theme)
            : FileIcons.image(for: FileType.of(fileNamed: node.name), theme: theme)
        cell.show(name: node.name,
                  detail: isSearching ? (node.relativePath as NSString).deletingLastPathComponent : nil,
                  icon: icon,
                  dimmed: kind == .ignored,
                  nameColor: color,
                  bold: current,
                  badge: kind?.badge ?? (node.isDirectory && model.status.containsChanges(node.relativePath) ? "•" : ""),
                  badgeColor: kind.map(theme.color(for:)) ?? theme.color(for: .modified))
    }

    // MARK: Clicks and keys

    /// A click previews a file or opens a folder.
    @objc private func clicked() {
        let row = outline.clickedRow
        // The disclosure triangle opens folders itself; the second click of a double-click is
        // handled as one.
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode, NSApp.currentEvent?.clickCount ?? 1 == 1,
              NSApp.currentEvent?.modifierFlags.intersection([.command, .shift]).isEmpty ?? true else { return }
        guard node.isDirectory else { return actions.preview(node.url) }
        guard !outline.frameOfOutlineCell(atRow: row).contains(outline.convert(NSApp.currentEvent?.locationInWindow ?? .zero, from: nil))
        else { return }
        toggle(node)
    }

    @objc private func doubleClicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode else { return }
        if isSearching, node.isDirectory { return reveal(node.url) }
        if !node.isDirectory { actions.open(node.url) }
    }

    private func toggle(_ node: FileNode) {
        if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
    }

    /// Return: opens files and folders.
    private func performPrimaryAction(on nodes: [FileNode]) {
        for node in nodes {
            if node.isDirectory {
                if isSearching {
                    clearSearch()
                    reveal(node.url)
                } else {
                    toggle(node)
                }
            } else {
                actions.open(node.url)
            }
        }
    }

    @objc private func searchChanged() {
        model.query = searchField.stringValue
        if !isSearching { outline.reloadData() }
    }

    private func clearSearch() {
        searchField.stringValue = ""
        searchChanged()
    }

    private func copyPaths(_ nodes: [FileNode], relative: Bool) {
        guard !nodes.isEmpty else { return }
        let paths = nodes.map { relative ? ($0.relativePath.isEmpty ? "." : $0.relativePath) : $0.url.path }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    /// The rows a context menu acts on: the selection when the clicked row is in it, else the clicked row.
    private var menuNodes: [FileNode] {
        let row = outline.clickedRow
        guard row >= 0 else { return outline.selectedNodes }
        if outline.selectedRowIndexes.contains(row) { return outline.selectedNodes }
        return (outline.item(atRow: row) as? FileNode).map { [$0] } ?? []
    }
}

// MARK: - Data source and delegate

extension FileTreeSidebar: NSOutlineViewDataSource, NSOutlineViewDelegate {
    private func items(of item: Any?) -> [FileNode] {
        if isSearching { return item == nil ? model.results : [] }
        guard let folder = (item as? FileNode) ?? model.root else { return [] }
        return model.children(of: folder)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        items(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        items(of: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !isSearching && (item as? FileNode)?.isDirectory == true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: FileCell.identifier, owner: nil) as? FileCell ?? FileCell()
        configure(cell, for: node)
        return cell
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        refreshFolderIcon(notification)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        refreshFolderIcon(notification)
    }

    /// Folders show open while expanded.
    private func refreshFolderIcon(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        let row = outline.row(forItem: node)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCell else { return }
        configure(cell, for: node)
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        (item as? FileNode)?.url as NSURL?
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        (item as? FileNode)?.name
    }
}

// MARK: - Filter field

extension FileTreeSidebar: NSSearchFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            window?.makeFirstResponder(outline)
            if outline.selectedRow < 0, outline.numberOfRows > 0 { outline.selectRowIndexes([0], byExtendingSelection: false) }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if isSearching, let first = model.results.first { performPrimaryAction(on: [first]) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if isSearching { clearSearch() } else { actions.focusTerminal() }
            return true
        default:
            return false
        }
    }
}

// MARK: - Context menu

extension FileTreeSidebar: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in contextMenuItems(for: menuNodes) { menu.addItem(item) }
    }

    func contextMenuItems(for nodes: [FileNode]) -> [NSMenuItem] {
        guard let first = nodes.first else { return [] }
        var items: [NSMenuItem] = []
        let urls = nodes.map(\.url)
        if nodes.count == 1, first.isDirectory {
            items.append(ClosureMenuItem("Change Directory Here", image: "arrow.right.to.line") { [weak self] in
                self?.actions.changeDirectory(first.url)
            })
            items.append(ClosureMenuItem("Open in New Tab", image: "plus.rectangle.on.rectangle") { [weak self] in
                self?.actions.openInNewTab(first.url)
            })
        } else if !first.isDirectory {
            items.append(ClosureMenuItem("Open", image: "doc.text") { [weak self] in
                urls.forEach { self?.actions.open($0) }
            })
            items.append(ClosureMenuItem("Open in Default App", image: "arrow.up.forward.app") { [weak self] in
                urls.forEach { self?.actions.openInDefaultApp($0) }
            })
            if nodes.count == 1 {
                items.append(ClosureMenuItem("Open in Terminal Editor", image: "apple.terminal") { [weak self] in
                    self?.actions.openInEditor(first.url)
                })
            }
        }
        items.append(.separator())
        items.append(ClosureMenuItem(nodes.count == 1 ? "Insert Path" : "Insert Paths", image: "text.insert") { [weak self] in
            self?.actions.insertPaths(urls)
        })
        items.append(ClosureMenuItem("Copy Path", image: "doc.on.doc") { [weak self] in
            self?.copyPaths(nodes, relative: false)
        })
        items.append(ClosureMenuItem("Copy Relative Path", image: "doc.on.doc") { [weak self] in
            self?.copyPaths(nodes, relative: true)
        })
        items.append(.separator())
        items.append(ClosureMenuItem("Reveal in Finder", image: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        })
        return items
    }
}

// MARK: - Views

/// The outline, with Return, Escape and ⌘C.
final class FileOutlineView: NSOutlineView {
    var onPrimaryAction: (() -> Void)?
    var onEscape: (() -> Void)?
    var onCopy: (() -> Void)?

    var selectedNodes: [FileNode] {
        selectedRowIndexes.compactMap { item(atRow: $0) as? FileNode }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onPrimaryAction?()  // Return, Enter
        case 53: onEscape?()
        default: super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) { onCopy?() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        item.action == #selector(copy(_:)) ? !selectedRowIndexes.isEmpty : super.validateUserInterfaceItem(item)
    }

    /// Right-clicking a row outside the selection shows that row's menu without moving the selection,
    /// as in Finder.
    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        return super.menu(for: event)
    }
}

/// One row: icon, name, the folder it's in while searching, and git's letter.
final class FileCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("FileCell")

    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        imageView = icon
        textField = name
        icon.imageScaling = .scaleNone
        name.lineBreakMode = .byTruncatingMiddle
        detail.lineBreakMode = .byTruncatingHead
        detail.textColor = .tertiaryLabelColor
        detail.font = .systemFont(ofSize: 11)
        badge.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        badge.alignment = .right
        for view in [icon, name, detail, badge] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        name.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 6),
            detail.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -4),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            badge.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(name text: String, detail folder: String?, icon image: NSImage, dimmed: Bool, nameColor: NSColor,
              bold: Bool, badge letter: String, badgeColor: NSColor) {
        name.stringValue = text
        name.font = .systemFont(ofSize: 12, weight: bold ? .semibold : .regular)
        name.textColor = nameColor
        detail.stringValue = folder ?? ""
        detail.isHidden = folder?.isEmpty ?? true
        icon.image = image
        icon.alphaValue = dimmed ? 0.45 : 1
        badge.stringValue = letter
        badge.textColor = badgeColor
        setAccessibilityLabel(letter.isEmpty || letter == "•" ? text : "\(text), \(letter)")
    }
}

/// The sidebar's trailing edge: drag to resize.
final class SidebarResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var lastX: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        lastX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        let x = event.locationInWindow.x
        onDrag?(x - lastX)
        lastX = x
    }
}

/// The root folder's name and the tree's options.
struct FileTreeHeader: View {
    @ObservedObject var model: FileTreeModel
    let theme: CodecTheme
    var collapseAll: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: model.isRepository ? "shippingbox" : "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(model.root?.name ?? "No folder")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.root?.url.path ?? "")
            Spacer(minLength: 4)
            HeaderButton(systemImage: model.showHidden ? "eye" : "eye.slash",
                         help: model.showHidden ? "Hide Hidden Files" : "Show Hidden Files") {
                model.showHidden.toggle()
            }
            HeaderButton(systemImage: "rectangle.compress.vertical", help: "Collapse All", action: collapseAll)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(maxHeight: .infinity)
    }
}

private struct HeaderButton: View {
    let systemImage: String
    let help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

extension CodecTheme {
    /// The color files of a git status are shown in.
    func color(for kind: GitStatus.Kind) -> NSColor {
        switch kind {
        case .modified: ansi[3]
        case .added, .untracked: ansi[2]
        case .deleted: ansi[1]
        case .renamed: ansi[4]
        case .conflicted: alert
        case .ignored: .tertiaryLabelColor
        }
    }
}
