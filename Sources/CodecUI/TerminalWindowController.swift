import AppKit
import SwiftUI
import Combine
import CodecCore

/// A Codec window: a tab bar, the selected tab's panes, a status bar and the command palette.
final class TerminalWindowController: NSWindowController, NSWindowDelegate, PaneHost {
    let model = WindowModel()
    var onClose: ((TerminalWindowController) -> Void)?

    private let environment: AppEnvironment
    private var preferences: Preferences { environment.preferences }
    private let backdrop = NSVisualEffectView()
    private let tint = NSView()
    let paneContainer = NSView()
    private(set) var tabBar: PassthroughHostingView<TabBar>!
    private(set) var statusBar: PassthroughHostingView<StatusBar>!
    private var palette: PassthroughHostingView<AnyView>!
    private var installedTab: TerminalTab?
    private var installedLayout: SplitLayout<Pane>?
    private var tabObservers: [UUID: AnyCancellable] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var firstResponderObservation: NSKeyValueObservation?

    init(directory: String?, environment: AppEnvironment) {
        self.environment = environment
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
            onSelect: { [weak self] in self?.select($0) },
            onClose: { [weak self] in self?.requestClose(tab: $0) },
            onNewTab: { [weak self] in self?.newTab(nil) },
            onPalette: { [weak self] in self?.showCommandPalette(nil) }))
        statusBar = PassthroughHostingView(rootView: StatusBar(model: model, preferences: preferences,
                                                               monitor: environment.systemMonitor))
        palette = PassthroughHostingView(rootView: AnyView(EmptyView()))
        palette.capturesMouse = false

        for view in [backdrop, tint, tabBar!, paneContainer, statusBar!, palette!] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate(
            backdrop.constraintsFilling(content) + tint.constraintsFilling(content) + palette.constraintsFilling(content) + [
                tabBar.topAnchor.constraint(equalTo: content.topAnchor),
                tabBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                tabBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                tabBar.heightAnchor.constraint(equalToConstant: TabBar.height),
                paneContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
                paneContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
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
        firstResponderObservation = window?.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.firstResponderChanged(window.firstResponder) }
        }
    }

    private func applyPreferences() {
        let theme = preferences.theme
        window?.appearance = theme.appearance
        backdrop.isHidden = !preferences.blur
        tint.layer?.backgroundColor = theme.background.withAlphaComponent(preferences.blur ? preferences.opacity : 1).cgColor
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
        if !model.paletteOpen, let window, window.firstResponder !== tab.focused.view.preferredResponder {
            window.makeFirstResponder(tab.focused.view.preferredResponder)
        }
        focusedPaneCameToFront()
        updateWindowTitle()
    }

    private func updateWindowTitle() {
        guard let window, let title = model.selected?.focused.session.title, window.title != title else { return }
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
        model.tabs.remove(at: index)
        if model.tabs.isEmpty {
            window?.close()
            return
        }
        if model.selectedID == tab.id {
            select(model.tabs[min(index, model.tabs.count - 1)])
        }
    }

    func requestClose(tab: TerminalTab) {
        confirmClosing(tab.panes, what: "this tab") { [weak self] in self?.removeTab(tab) }
    }

    /// Asks before closing panes that have programs running in them.
    private func confirmClosing(_ panes: [Pane], what: String, then close: @escaping () -> Void) {
        let busy = panes.filter(\.hasRunningJob)
        guard !busy.isEmpty, let window else {
            close()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Close \(what)?"
        let names = busy.map { "“\($0.session.processName)”" }.joined(separator: ", ")
        alert.informativeText = "\(names) \(busy.count == 1 ? "is" : "are") still running and will be terminated."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { close() }
        }
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
        if let pane = focusedPane { requestClose(pane) }
    }

    @objc func restartShell(_ sender: Any?) {
        focusedPane?.restart()
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
    }

    func hideCommandPalette() {
        guard model.paletteOpen else { return }
        model.paletteOpen = false
        palette.capturesMouse = false
        palette.rootView = AnyView(EmptyView())
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
            .init(id: "restart", title: "Restart Shell", systemImage: "arrow.clockwise") { [weak self] in self?.restartShell(nil) },
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
        for (index, tab) in model.tabs.enumerated() {
            commands.append(.init(id: "tab-\(tab.id)", title: "Go to Tab \(index + 1): \(tab.focused.session.title)",
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
        guard hasRunningJobs else { return true }
        confirmClosing(allPanes, what: "this window") { sender.close() }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        allPanes.forEach { $0.shutDown() }
        cancellables.removeAll()
        tabObservers.removeAll()
        onClose?(self)
    }
}
