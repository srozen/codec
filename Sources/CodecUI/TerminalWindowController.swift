import AppKit
import SwiftUI
import Combine
import CodecCore

/// A Codec window: a tab bar, the selected tab's panes, a status bar and the command palette.
final class TerminalWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, PaneHost {
    let model = WindowModel()
    var onClose: ((TerminalWindowController) -> Void)?

    private let environment: AppEnvironment
    private var preferences: Preferences { environment.preferences }
    private let backdrop = NSVisualEffectView()
    private let tint = NSView()
    let paneContainer = NSView()
    private(set) var tabBar: PassthroughHostingView<TabBar>!
    private(set) var statusBar: PassthroughHostingView<StatusBar>!
    private(set) var palette: PassthroughHostingView<AnyView>!
    private var installedTab: TerminalTab?
    private var installedLayout: SplitLayout<Pane>?
    private var tabObservers: [UUID: AnyCancellable] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var firstResponderObservation: NSKeyValueObservation?
    let fileTree: FileTreeModel
    private(set) var sidebar: FileTreeSidebar!
    private var sidebarWidth: NSLayoutConstraint!
    private var focusedDirectory: AnyCancellable?
    private weak var followedPane: Pane?
    let editor = EditorModel()
    private(set) var editorPanel: EditorPanel!
    private var editorWidth: NSLayoutConstraint!
    private static let editorWidthKey = "EditorWidth"
    private static let fileTreeVisibleKey = "FileTreeVisible"
    private static let fileTreeWidthKey = "FileTreeWidth"

    init(directory: String?, environment: AppEnvironment) {
        self.environment = environment
        fileTree = FileTreeModel(defaults: environment.preferences.stateDefaults)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize(font: environment.preferences.font())),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 520, height: 280)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        // An empty compact toolbar gives the title bar the tab bar's height, so the system keeps the
        // traffic lights centered on it.
        window.toolbar = NSToolbar(identifier: "codec.titlebar")
        window.toolbarStyle = .unifiedCompact
        window.titlebarSeparatorStyle = .none
        super.init(window: window)
        window.delegate = self

        buildContent()
        applyPreferences()
        observeEnvironment()
        addTab(directory: directory)
        setFileTreeVisible(preferences.stateDefaults.bool(forKey: Self.fileTreeVisibleKey))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Roughly 110 × 32 cells.
    private static func defaultSize(font: NSFont) -> NSSize {
        let cell = ("W" as NSString).size(withAttributes: [.font: font])
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return NSSize(width: ceil(cell.width * 110) + 40,
                      height: lineHeight * 32 + TabBar.height + StatusBar.height + 20)
    }

    // MARK: - Layout

    private func buildContent() {
        let content = NSView()
        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        tint.wantsLayer = true

        tabBar = PassthroughHostingView(rootView: TabBar(
            model: model,
            preferences: preferences,
            actions: TabBarActions(
                select: { [weak self] in self?.select($0) },
                close: { [weak self] in self?.requestClose(tab: $0) },
                newTab: { [weak self] in self?.newTab(nil) },
                showPalette: { [weak self] in self?.showCommandPalette(nil) },
                toggleFileTree: { [weak self] in self?.toggleFileTree(nil) },
                beginRenaming: { [weak self] in self?.beginRenaming($0) },
                finishRenaming: { [weak self] in self?.finishRenaming($0, to: $1) })))
        statusBar = PassthroughHostingView(rootView: StatusBar(model: model, preferences: preferences,
                                                               monitor: environment.systemMonitor))
        palette = PassthroughHostingView(rootView: AnyView(EmptyView()))
        palette.capturesMouse = false
        sidebar = FileTreeSidebar(model: fileTree, theme: preferences.theme)
        sidebar.actions = fileTreeActions()
        sidebar.onResize = { [weak self] width in self?.resizeFileTree(to: width) }
        sidebar.isHidden = true
        let storedWidth = preferences.stateDefaults.double(forKey: Self.fileTreeWidthKey)
        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: 0)
        fileTreeWidth = storedWidth > 0 ? min(max(CGFloat(storedWidth), FileTreeSidebar.widthRange.lowerBound), FileTreeSidebar.widthRange.upperBound) : FileTreeSidebar.defaultWidth

        editorPanel = EditorPanel(model: editor, theme: preferences.theme, font: preferences.font())
        editorPanel.openFile = { [weak self] url in self?.openFile(url, pin: true, focus: false) }
        editorPanel.onResize = { [weak self] width in self?.resizeEditor(to: width) }
        editorPanel.isHidden = true
        editorWidth = editorPanel.widthAnchor.constraint(equalToConstant: 0)
        editor.confirmClose = { [weak self] document, done in self?.confirmClosing(document, then: done) ?? done(true) }

        for view in [backdrop, tint, tabBar!, sidebar!, editorPanel!, paneContainer, statusBar!, palette!] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate(
            backdrop.constraintsFilling(content) + tint.constraintsFilling(content) + palette.constraintsFilling(content) + [
                tabBar.topAnchor.constraint(equalTo: content.topAnchor),
                tabBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                tabBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                tabBar.heightAnchor.constraint(equalToConstant: TabBar.height),
                sidebar.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
                sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                sidebar.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
                sidebarWidth,
                paneContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
                editorPanel.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
                editorPanel.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
                editorPanel.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
                editorWidth,
                paneContainer.leadingAnchor.constraint(equalTo: editorPanel.trailingAnchor),
                paneContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                paneContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
                statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                statusBar.heightAnchor.constraint(equalToConstant: StatusBar.height),
            ])
        window?.contentView = content
    }

    private func observeEnvironment() {
        NotificationCenter.default.publisher(for: Preferences.didChange, object: preferences)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.applyPreferences() } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.focusedPaneCameToFront() } }
            .store(in: &cancellables)
        editor.$documents
            .map(\.isEmpty)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateEditorVisibility() } }
            .store(in: &cancellables)
        firstResponderObservation = window?.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.firstResponderChanged(window.firstResponder) }
        }
    }

    private func applyPreferences() {
        let theme = preferences.theme
        window?.appearance = theme.appearance
        backdrop.isHidden = !preferences.blur
        tint.layer?.backgroundColor = theme.background.withAlphaComponent(preferences.blur ? preferences.opacity : 1).cgColor
        sidebar?.applyTheme(theme)
        editorPanel?.apply(theme: theme, font: preferences.font())
        allPanes.forEach { $0.applyPreferences() }
        installSelectedTab(force: true)
    }

    /// Puts the selected tab's panes in the window, rebuilding the view tree if the layout changed.
    private func installSelectedTab(force: Bool = false) {
        guard let tab = model.selected else { return }
        let layoutChanged = tab !== installedTab || installedLayout.map { !$0.isSameShape(as: tab.layout) } ?? true
        if force || layoutChanged {
            paneContainer.subviews.forEach { $0.removeFromSuperview() }
            let root = tab.makeView(divider: preferences.theme.divider)
            root.translatesAutoresizingMaskIntoConstraints = false
            paneContainer.addSubview(root)
            NSLayoutConstraint.activate(root.constraintsFilling(paneContainer))
            installedTab = tab
            installedLayout = tab.layout
        }
        updatePaneFocus()
    }

    /// Dims inactive panes and gives the focused one the keyboard.
    private func updatePaneFocus() {
        guard let tab = model.selected else { return }
        let dim = preferences.dimInactivePanes && tab.panes.count > 1
        for pane in tab.panes {
            pane.view.setDimmed(dim && pane !== tab.focused)
        }
        if !model.paletteOpen, model.renamingTabID == nil,
           let window, window.firstResponder !== tab.focused.view.preferredResponder {
            window.makeFirstResponder(tab.focused.view.preferredResponder)
        }
        focusedPaneCameToFront()
        updateWindowTitle()
        followFocusedDirectory()
    }

    private func updateWindowTitle() {
        guard let window, let title = model.selected?.title, window.title != title else { return }
        window.title = title
    }

    private func focusedPaneCameToFront() {
        guard let pane = focusedPane, isInFront(pane) else { return }
        pane.didComeToFront()
    }

    private func firstResponderChanged(_ responder: NSResponder?) {
        guard let view = responder as? NSView, let tab = model.selected,
              let pane = tab.panes.first(where: { view.isDescendant(of: $0.view) }),
              pane !== tab.focused else { return }
        tab.focus(pane)
    }

    // MARK: - File tree

    private var fileTreeWidth: CGFloat = FileTreeSidebar.defaultWidth

    func setFileTreeVisible(_ visible: Bool) {
        model.fileTreeVisible = visible
        preferences.stateDefaults.set(visible, forKey: Self.fileTreeVisibleKey)
        sidebar.isHidden = !visible
        sidebarWidth.constant = visible ? fileTreeWidth : 0
        if visible, let pane = focusedPane { fileTree.follow(pane.session.directory) }
        fileTree.isActive = visible
        if visible, let directory = fileTree.currentDirectory { sidebar.reveal(directory) }
        if !visible, let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: sidebar) {
            focusTerminal()
        }
    }

    private func resizeFileTree(to width: CGFloat) {
        // Leave the terminal room for a usable number of columns.
        let maximum = min(FileTreeSidebar.widthRange.upperBound, (window?.frame.width ?? 1000) - 320)
        fileTreeWidth = min(max(width, FileTreeSidebar.widthRange.lowerBound), max(maximum, FileTreeSidebar.widthRange.lowerBound))
        sidebarWidth.constant = fileTreeWidth
        preferences.stateDefaults.set(Double(fileTreeWidth), forKey: Self.fileTreeWidthKey)
    }

    /// Keeps the tree on the focused pane's directory.
    private func followFocusedDirectory() {
        guard let pane = focusedPane, pane !== followedPane else { return }
        followedPane = pane
        focusedDirectory = pane.session.$directory
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] directory in MainActor.assumeIsolated { self?.fileTree.follow(directory) } }
    }

    private func focusTerminal() {
        guard let pane = focusedPane else { return }
        window?.makeFirstResponder(pane.view.preferredResponder)
    }

    private func fileTreeActions() -> FileTreeActions {
        FileTreeActions(
            preview: { [weak self] url in self?.openFile(url, pin: false, focus: false) },
            open: { [weak self] url in self?.openFile(url, pin: true, focus: true) },
            openInEditor: { [weak self] url in self?.openInEditor(url) },
            changeDirectory: { [weak self] url in
                guard let self else { return }
                if self.focusedPane?.runAtPrompt("cd " + ShellQuoting.quote(url.path)) == true {
                    self.focusTerminal()
                } else {
                    self.addTab(directory: url.path)
                }
            },
            openInNewTab: { [weak self] url in self?.addTab(directory: url.path) },
            insertPaths: { [weak self] urls in
                self?.focusedPane?.insertPaths(urls)
                self?.focusTerminal()
            },
            focusTerminal: { [weak self] in self?.focusTerminal() })
    }

    // MARK: - Editor

    /// Shows a file in the editor. Unpinned, it replaces the preview tab; focused, typing goes to it.
    func openFile(_ url: URL, pin: Bool, focus: Bool) {
        editor.open(url, pin: pin)
        updateEditorVisibility()
        editorPanel.update()
        if focus {
            window?.layoutIfNeeded()
            editorPanel.focus()
        }
    }

    private func updateEditorVisibility() {
        let visible = !editor.documents.isEmpty
        guard visible == editorPanel.isHidden else { return }
        if !visible, editorPanel.hasFocus { focusTerminal() }
        editorPanel.isHidden = !visible
        if visible {
            let stored = CGFloat(preferences.stateDefaults.double(forKey: Self.editorWidthKey))
            let available = (window?.contentView?.bounds.width ?? 1000) - sidebarWidth.constant
            editorWidth.constant = clampedEditorWidth(stored > 0 ? stored : available * 0.5)
        } else {
            editorWidth.constant = 0
        }
    }

    private func clampedEditorWidth(_ width: CGFloat) -> CGFloat {
        let available = (window?.contentView?.bounds.width ?? 1000) - sidebarWidth.constant
        return max(280, min(width, available - 320))
    }

    private func resizeEditor(to width: CGFloat) {
        editorWidth.constant = clampedEditorWidth(width)
        preferences.stateDefaults.set(Double(editorWidth.constant), forKey: Self.editorWidthKey)
    }

    /// Asks whether to save a file's changes before closing it.
    private func confirmClosing(_ document: EditorDocument, then done: @escaping (Bool) -> Void) {
        guard let window else { return done(true) }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(document.name)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: done(self?.save(document) ?? false)
            case .alertSecondButtonReturn: done(true)
            default: done(false)
            }
        }
    }

    /// Saves, telling the user when it fails. True when it worked.
    @discardableResult
    private func save(_ document: EditorDocument) -> Bool {
        do {
            try document.save()
            return true
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "“\(document.name)” couldn’t be saved."
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return false
        }
    }

    var hasUnsavedFiles: Bool { editor.hasUnsavedChanges }

    @objc func saveDocument(_ sender: Any?) {
        guard let document = editor.selected, document.isEditable, document.kind != .otherEncoding else { return NSSound.beep() }
        save(document)
    }

    @objc func closeFile(_ sender: Any?) {
        guard let document = editor.selected else { return NSSound.beep() }
        let hadFocus = editorPanel.hasFocus
        editor.close(document) { [weak self] in
            guard let self else { return }
            self.updateEditorVisibility()
            self.editorPanel.update()
            guard hadFocus else { return }
            if self.editor.documents.isEmpty { self.focusTerminal() } else { self.editorPanel.focus() }
        }
    }

    @objc func toggleMarkdownPreview(_ sender: Any?) {
        guard let document = editor.selected, document.kind == .markdown else { return NSSound.beep() }
        document.mode = document.mode == .preview ? .source : .preview
        editorPanel.update()
    }

    private func showMarkdown(_ mode: EditorDocument.Mode) {
        guard let document = editor.selected, document.kind == .markdown else { return NSSound.beep() }
        document.mode = mode
        editorPanel.update()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(saveDocument(_:)): return editor.selected.map { $0.isEditable && $0.kind != .otherEncoding } ?? false
        case #selector(closeFile(_:)): return editor.selected != nil
        case #selector(toggleMarkdownPreview(_:)): return editor.selected?.kind == .markdown
        default: return true
        }
    }

    /// Opens a file in `$EDITOR` (vi without one) in a new pane to the right.
    func openInEditor(_ url: URL) {
        guard let pane = focusedPane, let tab = model.tabs.first(where: { $0.layout.contains(pane) }) else { return }
        let editor = makePane(directory: url.deletingLastPathComponent().path)
        tab.split(pane, with: editor, axis: .horizontal)
        editor.terminal.send(txt: "${EDITOR:-vi} " + ShellQuoting.quote("./" + url.lastPathComponent) + "\r")
    }

    // MARK: - Tabs & panes

    private func makePane(directory: String?) -> Pane {
        let pane = Pane(directory: directory, environment: environment)
        pane.host = self
        if preferences.paneSounds { environment.sounds.play(.lock) }
        return pane
    }

    private var focusedPane: Pane? { model.selected?.focused }
    var allPanes: [Pane] { model.tabs.flatMap(\.panes) }

    func addTab(directory: String?) {
        let tab = TerminalTab(pane: makePane(directory: directory))
        tab.onLayoutChange = { [weak self, weak tab] in
            guard let self, let tab, tab === self.model.selected else { return }
            self.installSelectedTab()
        }
        // Session changes arrive as "will change"; read the new title once they've landed.
        tabObservers[tab.id] = tab.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] _ in
                MainActor.assumeIsolated {
                    guard let self, let tab, tab === self.model.selected else { return }
                    self.updateWindowTitle()
                }
            }
        let position = model.selected.flatMap { selected in model.tabs.firstIndex { $0 === selected } }.map { $0 + 1 }
        model.tabs.insert(tab, at: position ?? model.tabs.count)
        select(tab)
    }

    func select(_ tab: TerminalTab) {
        model.selectedID = tab.id
        installSelectedTab()
    }

    /// Shows the pane with this session ID. Returns false if it isn't in this window.
    func reveal(sessionID: String) -> Bool {
        for tab in model.tabs {
            if let pane = tab.panes.first(where: { $0.session.id.uuidString == sessionID }) {
                select(tab)
                tab.focus(pane)
                window?.makeKeyAndOrderFront(nil)
                return true
            }
        }
        return false
    }

    private func remove(_ pane: Pane) {
        guard let tab = model.tabs.first(where: { $0.layout.contains(pane) }) else { return }
        pane.shutDown()
        if preferences.paneSounds { environment.sounds.play(.exit) }
        if tab.remove(pane) {
            removeTab(tab)
        } else if tab === model.selected {
            installSelectedTab()
        }
        environment.coordinator?.attentionDidChange()
    }

    private func removeTab(_ tab: TerminalTab) {
        guard let index = model.tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.panes.forEach { $0.shutDown() }
        tabObservers[tab.id] = nil
        if model.renamingTabID == tab.id { model.renamingTabID = nil }
        model.tabs.remove(at: index)
        if model.tabs.isEmpty {
            window?.close()
            return
        }
        if model.selectedID == tab.id {
            select(model.tabs[min(index, model.tabs.count - 1)])
        }
    }

    // MARK: Renaming

    /// Shows the name editor on `tab`'s button.
    func beginRenaming(_ tab: TerminalTab) {
        guard model.tabs.contains(where: { $0 === tab }) else { return }
        if model.paletteOpen { hideCommandPalette() }
        select(tab)
        model.renamingTabID = tab.id
    }

    /// Ends editing `tab`'s name: `name` renames it (blank resets it), nil cancels.
    func finishRenaming(_ tab: TerminalTab, to name: String?) {
        if let name { tab.rename(to: name) }
        guard model.renamingTabID != nil else {
            updateWindowTitle()
            return
        }
        model.renamingTabID = nil
        updateWindowTitle()
        if tab === model.selected, let pane = focusedPane {
            window?.makeFirstResponder(pane.view.preferredResponder)
        }
    }

    func requestClose(tab: TerminalTab) {
        confirmClosing(tab.panes, what: "this tab") { [weak self] in self?.removeTab(tab) }
    }

    /// Asks before closing panes that have programs running in them.
    private func confirmClosing(_ panes: [Pane], what: String, then close: @escaping () -> Void) {
        var programs: [String] = []
        for pane in panes {
            for program in pane.runningPrograms where !programs.contains(program) { programs.append(program) }
        }
        guard !programs.isEmpty, let window else {
            close()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Close \(what)?"
        alert.informativeText = "\(RunningPrograms.list(programs)) \(programs.count == 1 ? "is" : "are") still running and will be terminated."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { close() }
        }
    }

    /// Everything the window's panes would terminate if it closed, each program once.
    var runningPrograms: [String] {
        var programs: [String] = []
        for pane in allPanes {
            for program in pane.runningPrograms where !programs.contains(program) { programs.append(program) }
        }
        return programs
    }

    var hasRunningJobs: Bool {
        allPanes.contains(where: \.hasRunningJob)
    }

    // MARK: - PaneHost

    func isInFront(_ pane: Pane) -> Bool {
        NSApp.isActive && window?.isKeyWindow == true && model.selected?.focused === pane
    }

    func split(_ pane: Pane, axis: SplitAxis) {
        guard let tab = model.tabs.first(where: { $0.layout.contains(pane) }) else { return }
        tab.split(pane, with: makePane(directory: pane.session.directory), axis: axis)
    }

    func requestClose(_ pane: Pane) {
        confirmClosing([pane], what: "this pane") { [weak self] in self?.remove(pane) }
    }

    func paneDidFinish(_ pane: Pane) {
        remove(pane)
    }

    // MARK: - History

    private var historyPopover: NSPopover?
    private var historyPopoverClosed: NSObjectProtocol?
    var isShowingHistoryMenu: Bool { historyPopover?.isShown == true }
    private(set) var isShowingHistoryPanel = false

    func showHistory(for pane: Pane, request: IntegrationEvent.HistoryRequest, typed: String) {
        guard let tab = model.tabs.first(where: { $0.layout.contains(pane) }) else { return }
        if tab !== model.selected { select(tab) }
        tab.focus(pane)
        switch request {
        case .menu: showHistoryMenu(for: pane, typed: typed)
        case .search: showHistoryPanel(for: pane, typed: typed)
        }
    }

    /// ⌘Y: the history search, for the focused pane.
    @objc func showCommandHistory(_ sender: Any?) {
        if isShowingHistoryPanel { return hideCommandPalette() }
        guard let pane = focusedPane else { return NSSound.beep() }
        showHistoryPanel(for: pane, typed: "")
    }

    private func historyView(for pane: Pane, style: HistoryView.Style, typed: String,
                             dismiss: @escaping () -> Void) -> HistoryView {
        // Picks up commands other terminals added to the shell's history file.
        environment.history.load()
        return HistoryView(store: environment.history, style: style, theme: preferences.theme, codeFont: preferences.font(),
                           directory: pane.session.directory, canInsert: pane.isAtCommandLine, query: typed,
                           onChoose: { [weak self, weak pane] choice in
                               dismiss()
                               self?.apply(choice, to: pane)
                           },
                           onDismiss: dismiss)
    }

    private func apply(_ choice: HistoryChoice, to pane: Pane?) {
        switch choice {
        case .insert(let command): pane?.replaceCommandLine(with: command, run: false)
        case .run(let command): pane?.replaceCommandLine(with: command, run: true)
        case .copy(let command):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
        if let pane { window?.makeFirstResponder(pane.view.preferredResponder) }
    }

    /// ↑ at the prompt: a menu just above the cursor.
    private func showHistoryMenu(for pane: Pane, typed: String) {
        historyPopover?.close()
        guard let grid = TerminalGrid(terminal: pane.terminal) else { return showHistoryPanel(for: pane, typed: typed) }
        let popover = NSPopover()
        popover.behavior = .transient
        let controller = NSHostingController(rootView: historyView(for: pane, style: .menu, typed: typed) { [weak popover] in
            popover?.performClose(nil)
        })
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
        historyPopoverClosed = NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification, object: popover, queue: .main) { [weak self, weak pane] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let observer = self.historyPopoverClosed { NotificationCenter.default.removeObserver(observer) }
                self.historyPopoverClosed = nil
                self.historyPopover = nil
                self.stopWatchingOverlayKeys()
                if let pane, !self.model.paletteOpen { self.window?.makeFirstResponder(pane.view.preferredResponder) }
            }
        }
        historyPopover = popover
        popover.show(relativeTo: pane.terminal.convert(grid.caret, from: nil), of: pane.terminal, preferredEdge: .maxY)
        watchOverlayKeys()
        focusSearchField(in: controller.view)
    }

    /// ⌃R at the prompt, or ⌘Y: the full search, over the window like the command palette.
    private func showHistoryPanel(for pane: Pane, typed: String) {
        historyPopover?.close()
        if model.paletteOpen { hideCommandPalette() }
        model.paletteOpen = true
        isShowingHistoryPanel = true
        let view = historyView(for: pane, style: .panel, typed: typed) { [weak self] in self?.hideCommandPalette() }
        palette.rootView = AnyView(
            ZStack(alignment: .top) {
                Color.black.opacity(0.001)
                    .onTapGesture { [weak self] in self?.hideCommandPalette() }
                view
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
                    .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
                    .padding(.top, TabBar.height + 36)
            })
        palette.capturesMouse = true
        watchOverlayKeys()
        focusSearchField(in: palette)
    }

    // MARK: Overlay keyboard

    private var overlayKeyMonitor: Any?

    /// Puts the keyboard in an overlay's search field. Opened from the shell (⌃R, ↑), the overlay
    /// appears outside a key event, and SwiftUI's own focus request doesn't always land.
    /// SwiftUI builds the field a little later the first time, and its own focus handling can let go
    /// of it again while it settles. So for up to a second this keeps putting the keyboard back in the
    /// field, until it has stayed there for a few checks in a row.
    private func focusSearchField(in view: NSView, attempt: Int = 0, held: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.02)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, view.window != nil else { return }
                view.layoutSubtreeIfNeeded()
                var holding = 0
                if let field = Self.firstTextField(in: view), let window = field.window {
                    if Self.isEditing(field, in: window) {
                        holding = held + 1
                    } else {
                        if !window.isKeyWindow { window.makeKey() }
                        window.makeFirstResponder(field)
                    }
                }
                if holding < 3, attempt < 50 { self.focusSearchField(in: view, attempt: attempt + 1, held: holding) }
            }
        }
    }

    private static func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = firstTextField(in: subview) { return field }
        }
        return nil
    }

    private static func isEditing(_ field: NSTextField, in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder as? NSView else { return false }
        return responder === field || responder.isDescendant(of: field) || (responder as? NSText)?.delegate === field
    }

    /// While the palette, the history panel or the history menu is open: Esc closes it, and typing
    /// goes to its search field, wherever the keyboard ended up.
    private func watchOverlayKeys() {
        guard overlayKeyMonitor == nil else { return }
        overlayKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleOverlayKey(event) ?? false }
            return consumed ? nil : event
        }
    }

    private func stopWatchingOverlayKeys() {
        guard !model.paletteOpen, !isShowingHistoryMenu, let monitor = overlayKeyMonitor else { return }
        NSEvent.removeMonitor(monitor)
        overlayKeyMonitor = nil
    }

    /// Handles a key pressed while an overlay is open. True when it was used up here.
    func handleOverlayKey(_ event: NSEvent) -> Bool {
        let menuWindow = historyPopover?.contentViewController?.view.window
        guard event.window === window || (menuWindow != nil && event.window === menuWindow) else { return false }
        if let popover = historyPopover, popover.isShown {
            if event.keyCode == 53 {
                popover.performClose(nil)
                return true
            }
            if let content = popover.contentViewController?.view, let field = Self.firstTextField(in: content),
               let menuWindow, !Self.isEditing(field, in: menuWindow) {
                menuWindow.makeKey()
                menuWindow.makeFirstResponder(field)
            }
            return false
        }
        guard model.paletteOpen else {
            stopWatchingOverlayKeys()
            return false
        }
        if event.keyCode == 53 {
            hideCommandPalette()
            return true
        }
        if let window, let field = Self.firstTextField(in: palette), !Self.isEditing(field, in: window) {
            window.makeFirstResponder(field)
        }
        return false
    }

    // MARK: - Actions (menus, shortcuts and the palette)

    @objc func newTab(_ sender: Any?) {
        addTab(directory: focusedPane?.session.directory)
    }

    @objc func splitRight(_ sender: Any?) {
        if let pane = focusedPane { split(pane, axis: .horizontal) }
    }

    @objc func splitDown(_ sender: Any?) {
        if let pane = focusedPane { split(pane, axis: .vertical) }
    }

    @objc func closePane(_ sender: Any?) {
        // ⌘W closes the file when the editor has the keyboard.
        if editorPanel.hasFocus, editor.selected != nil { return closeFile(sender) }
        if let pane = focusedPane { requestClose(pane) }
    }

    @objc func restartShell(_ sender: Any?) {
        focusedPane?.restart()
    }

    @objc func renameTab(_ sender: Any?) {
        if let tab = model.selected { beginRenaming(tab) }
    }

    @objc func nextTab(_ sender: Any?) { cycleTab(by: 1) }

    @objc func previousTab(_ sender: Any?) { cycleTab(by: -1) }

    private func cycleTab(by delta: Int) {
        guard let selected = model.selected, let index = model.tabs.firstIndex(where: { $0 === selected }) else { return }
        select(model.tabs[(index + delta + model.tabs.count) % model.tabs.count])
    }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        let index = sender.tag == 9 ? model.tabs.count - 1 : sender.tag - 1
        guard model.tabs.indices.contains(index) else { return }
        select(model.tabs[index])
    }

    @objc func nextPane(_ sender: Any?) { model.selected?.cyclePane(forward: true) }
    @objc func previousPane(_ sender: Any?) { model.selected?.cyclePane(forward: false) }
    @objc func focusPaneLeft(_ sender: Any?) { model.selected?.focusNeighbor(.left) }
    @objc func focusPaneRight(_ sender: Any?) { model.selected?.focusNeighbor(.right) }
    @objc func focusPaneUp(_ sender: Any?) { model.selected?.focusNeighbor(.up) }
    @objc func focusPaneDown(_ sender: Any?) { model.selected?.focusNeighbor(.down) }

    @objc func biggerFont(_ sender: Any?) { allPanes.forEach { $0.changeFontSize(by: 1) } }
    @objc func smallerFont(_ sender: Any?) { allPanes.forEach { $0.changeFontSize(by: -1) } }
    @objc func resetFontSize(_ sender: Any?) { allPanes.forEach { $0.resetFontSize() } }

    @objc func clearBuffer(_ sender: Any?) { focusedPane?.clearBuffer() }

    @objc func toggleFileTree(_ sender: Any?) {
        setFileTreeVisible(!model.fileTreeVisible)
        if model.fileTreeVisible { window?.makeFirstResponder(sidebar.outline) }
    }

    @objc func switchBranch(_ sender: Any?) {
        guard let pane = focusedPane else { return NSSound.beep() }
        pane.showBranchPicker()
    }

    @objc func copyLastOutput(_ sender: Any?) {
        guard let pane = focusedPane, let output = pane.lastOutputRange else { return NSSound.beep() }
        pane.copyOutput(output)
    }

    @objc func selectLastOutput(_ sender: Any?) {
        guard let pane = focusedPane, let output = pane.lastOutputRange else { return NSSound.beep() }
        pane.selectOutput(output)
    }

    @objc func moveToStartOfCommandLine(_ sender: Any?) { focusedPane?.editCommandLine(.moveToStart) }
    @objc func moveToEndOfCommandLine(_ sender: Any?) { focusedPane?.editCommandLine(.moveToEnd) }
    @objc func selectToStartOfCommandLine(_ sender: Any?) { focusedPane?.editCommandLine(.selectToStart) }
    @objc func selectToEndOfCommandLine(_ sender: Any?) { focusedPane?.editCommandLine(.selectToEnd) }
    @objc func deleteToStartOfCommandLine(_ sender: Any?) { focusedPane?.editCommandLine(.deleteToStart) }
    @objc func selectCommandLine(_ sender: Any?) { focusedPane?.editCommandLine(.selectAll) }
    @objc func previousCommand(_ sender: Any?) { focusedPane?.jumpToCommand(previous: true) }
    @objc func nextCommand(_ sender: Any?) { focusedPane?.jumpToCommand(previous: false) }

    @objc func showCommandPalette(_ sender: Any?) {
        if model.paletteOpen {
            hideCommandPalette()
            return
        }
        model.paletteOpen = true
        palette.rootView = AnyView(
            ZStack(alignment: .top) {
                Color.black.opacity(0.001)
                    .onTapGesture { [weak self] in self?.hideCommandPalette() }
                CommandPalette(commands: paletteCommands(), onDismiss: { [weak self] in self?.hideCommandPalette() })
                    .padding(.top, TabBar.height + 36)
            })
        palette.capturesMouse = true
        watchOverlayKeys()
        focusSearchField(in: palette)
    }

    func hideCommandPalette() {
        guard model.paletteOpen else { return }
        model.paletteOpen = false
        isShowingHistoryPanel = false
        palette.capturesMouse = false
        palette.rootView = AnyView(EmptyView())
        stopWatchingOverlayKeys()
        if let pane = focusedPane { window?.makeFirstResponder(pane.view.preferredResponder) }
    }

    func paletteCommands() -> [PaletteCommand] {
        var commands: [PaletteCommand] = [
            .init(id: "new-tab", title: "New Tab", shortcut: "⌘T", systemImage: "plus.square") { [weak self] in self?.newTab(nil) },
            .init(id: "new-window", title: "New Window", shortcut: "⌘N", systemImage: "macwindow.badge.plus") { [weak self] in
                self?.environment.coordinator?.newWindow()
            },
            .init(id: "split-right", title: "Split Pane Right", shortcut: "⌘D", systemImage: "rectangle.split.2x1") { [weak self] in self?.splitRight(nil) },
            .init(id: "split-down", title: "Split Pane Down", shortcut: "⇧⌘D", systemImage: "rectangle.split.1x2") { [weak self] in self?.splitDown(nil) },
            .init(id: "close-pane", title: "Close Pane", shortcut: "⌘W", systemImage: "xmark.square") { [weak self] in self?.closePane(nil) },
            .init(id: "next-pane", title: "Focus Next Pane", shortcut: "⌘]", systemImage: "arrow.right.square") { [weak self] in self?.nextPane(nil) },
            .init(id: "previous-pane", title: "Focus Previous Pane", shortcut: "⌘[", systemImage: "arrow.left.square") { [weak self] in self?.previousPane(nil) },
            .init(id: "next-tab", title: "Next Tab", shortcut: "⇧⌘]", systemImage: "chevron.right") { [weak self] in self?.nextTab(nil) },
            .init(id: "previous-tab", title: "Previous Tab", shortcut: "⇧⌘[", systemImage: "chevron.left") { [weak self] in self?.previousTab(nil) },
            .init(id: "previous-command", title: "Jump to Previous Command", shortcut: "⌘↑", systemImage: "arrow.up.to.line") { [weak self] in self?.previousCommand(nil) },
            .init(id: "next-command", title: "Jump to Next Command", shortcut: "⌘↓", systemImage: "arrow.down.to.line") { [weak self] in self?.nextCommand(nil) },
            .init(id: "clear", title: "Clear Buffer", shortcut: "⌘K", systemImage: "eraser") { [weak self] in self?.clearBuffer(nil) },
            .init(id: "copy-output", title: "Copy Output of Last Command", shortcut: "⇧⌘C", systemImage: "doc.on.doc.fill") { [weak self] in
                self?.copyLastOutput(nil)
            },
            .init(id: "select-output", title: "Select Output of Last Command", shortcut: "⇧⌘A", systemImage: "text.line.first.and.arrowtriangle.forward") { [weak self] in
                self?.selectLastOutput(nil)
            },
            .init(id: "file-tree", title: model.fileTreeVisible ? "Hide File Tree" : "Show File Tree", shortcut: "⇧⌘E",
                  systemImage: "sidebar.left") { [weak self] in self?.toggleFileTree(nil) },
            .init(id: "command-history", title: "Search Command History", shortcut: "⌘Y", systemImage: "clock.arrow.circlepath") { [weak self] in
                self?.showCommandHistory(nil)
            },
            .init(id: "save-file", title: "Save File", shortcut: "⌘S", systemImage: "square.and.arrow.down") { [weak self] in
                self?.saveDocument(nil)
            },
            .init(id: "close-file", title: "Close File", systemImage: "xmark.square") { [weak self] in self?.closeFile(nil) },
            .init(id: "markdown-source", title: "Markdown: Show Source", systemImage: "doc.plaintext") { [weak self] in
                self?.showMarkdown(.source)
            },
            .init(id: "markdown-split", title: "Markdown: Show Source and Preview", systemImage: "rectangle.split.2x1") { [weak self] in
                self?.showMarkdown(.split)
            },
            .init(id: "markdown-preview", title: "Markdown: Show Preview", shortcut: "⇧⌘V", systemImage: "doc.richtext") { [weak self] in
                self?.showMarkdown(.preview)
            },
            .init(id: "switch-branch", title: "Switch Branch…", shortcut: "⇧⌘B", systemImage: "arrow.triangle.branch") { [weak self] in
                self?.switchBranch(nil)
            },
            .init(id: "restart", title: "Restart Shell", systemImage: "arrow.clockwise") { [weak self] in self?.restartShell(nil) },
            .init(id: "rename-tab", title: "Rename Tab…", shortcut: "⇧⌘R", systemImage: "pencil") { [weak self] in self?.renameTab(nil) },
            .init(id: "find", title: "Find…", shortcut: "⌘F", systemImage: "magnifyingglass") { [weak self] in
                let item = NSMenuItem()
                item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
                self?.focusedPane?.terminal.performFindPanelAction(item)
            },
            .init(id: "bigger", title: "Increase Font Size", shortcut: "⌘+", systemImage: "textformat.size.larger") { [weak self] in self?.biggerFont(nil) },
            .init(id: "smaller", title: "Decrease Font Size", shortcut: "⌘−", systemImage: "textformat.size.smaller") { [weak self] in self?.smallerFont(nil) },
            .init(id: "reset-font", title: "Reset Font Size", shortcut: "⌘0", systemImage: "textformat.size") { [weak self] in self?.resetFontSize(nil) },
            .init(id: "reveal", title: "Open Current Directory in Finder", systemImage: "folder") { [weak self] in
                guard let directory = self?.focusedPane?.session.directory, !directory.isEmpty else { return }
                NSWorkspace.shared.open(URL(fileURLWithPath: directory))
            },
            .init(id: "fullscreen", title: "Toggle Full Screen", shortcut: "⌃⌘F", systemImage: "arrow.up.left.and.arrow.down.right") { [weak self] in
                self?.window?.toggleFullScreen(nil)
            },
            .init(id: "settings", title: "Settings…", shortcut: "⌘,", systemImage: "gearshape") { [weak self] in
                self?.environment.coordinator?.showSettings()
            },
        ]
        let preferences = self.preferences
        for theme in CodecTheme.all {
            commands.append(.init(id: "theme-\(theme.id)", title: "Theme: \(theme.name)", systemImage: "paintpalette") {
                preferences.themeID = theme.id
            })
        }
        commands.append(.init(id: "system-stats", title: preferences.showSystemStats ? "Hide System Meters" : "Show System Meters",
                              systemImage: "gauge.with.dots.needle.33percent") {
            preferences.showSystemStats.toggle()
        })
        commands.append(.init(id: "scanlines", title: preferences.scanlines ? "Turn Off Scanlines" : "Turn On Scanlines",
                              systemImage: "line.3.horizontal") {
            preferences.scanlines.toggle()
        })
        if let tab = model.selected, tab.customTitle != nil {
            commands.append(.init(id: "reset-tab-name", title: "Reset Tab Name", systemImage: "arrow.uturn.backward") { [weak self] in
                self?.finishRenaming(tab, to: "")
            })
        }
        for (index, tab) in model.tabs.enumerated() {
            commands.append(.init(id: "tab-\(tab.id)", title: "Go to Tab \(index + 1): \(tab.title)",
                                  shortcut: index < 9 ? "⌘\(index + 1)" : nil, systemImage: "square.on.square") { [weak self] in
                self?.select(tab)
            })
        }
        return commands
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) { focusedPaneCameToFront() }

    func windowWillEnterFullScreen(_ notification: Notification) { model.fullScreen = true }

    func windowDidExitFullScreen(_ notification: Notification) { model.fullScreen = false }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if hasUnsavedFiles {
            confirmDiscardingUnsavedFiles { [weak self] in
                guard let self else { return }
                if self.hasRunningJobs {
                    self.confirmClosing(self.allPanes, what: "this window") { sender.close() }
                } else {
                    sender.close()
                }
            }
            return false
        }
        guard hasRunningJobs else { return true }
        confirmClosing(allPanes, what: "this window") { sender.close() }
        return false
    }

    /// Offers to save every file with unsaved changes, then goes ahead unless cancelled.
    func confirmDiscardingUnsavedFiles(then proceed: @escaping () -> Void) {
        let dirty = editor.documents.filter(\.isDirty)
        guard !dirty.isEmpty, let window else { return proceed() }
        let alert = NSAlert()
        alert.messageText = dirty.count == 1 ? "Save changes to “\(dirty[0].name)”?" : "Save changes to \(dirty.count) files?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: dirty.count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                if dirty.allSatisfy({ self?.save($0) ?? false }) { proceed() }
            case .alertSecondButtonReturn: proceed()
            default: break
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let monitor = overlayKeyMonitor { NSEvent.removeMonitor(monitor) }
        overlayKeyMonitor = nil
        allPanes.forEach { $0.shutDown() }
        cancellables.removeAll()
        tabObservers.removeAll()
        onClose?(self)
    }
}
