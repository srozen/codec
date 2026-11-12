import AppKit
import SwiftUI
import Combine
import CodecCore

/// A pane's commands, published for the Commands sidebar. Changes only when something did.
@MainActor
final class PaneTimeline: ObservableObject {
    @Published private(set) var value = CommandTimeline()
    /// The sidebar lists commands from this id on: clearing the list hides the older ones, but they're
    /// still tracked, for Copy Output.
    @Published private(set) var listStart = 0

    var entries: [TimelineEntry] { value.entries }
    var running: TimelineEntry? { value.running }

    func begin(command: String, directory: String, started: Date, block: CommandBlocks.Block?, usualDuration: TimeInterval?,
               toolchain: Toolchain? = nil) {
        value.begin(command: command, directory: directory, started: started, block: block, usualDuration: usualDuration,
                    toolchain: toolchain)
    }

    func setRunningUsualDuration(_ usual: TimeInterval?) {
        guard let running, running.usualDuration != usual else { return }
        value.setRunningUsualDuration(usual)
    }

    func updateRunningCommand(_ command: String) {
        guard let running, running.command != command else { return }
        value.updateRunningCommand(command)
    }

    func markRunningFullScreen() {
        guard running?.fullScreen == false else { return }
        value.markRunningFullScreen()
    }

    func finish(exitCode: Int32, duration: TimeInterval, output: CapturedOutput?) {
        guard running != nil else { return }
        value.finish(exitCode: exitCode, duration: duration, output: output)
    }

    func setOutput(_ output: CapturedOutput, of id: Int) {
        value.setOutput(output, of: id)
    }

    func abandonRunning() {
        guard running != nil else { return }
        value.abandonRunning()
    }

    func forgetBlocks() {
        guard value.entries.contains(where: { $0.block != nil }) else { return }
        value.forgetBlocks()
    }

    func forgetBlock(of id: Int) {
        guard value.entry(id: id)?.block != nil else { return }
        value.forgetBlock(of: id)
    }

    func setBlocks(_ blocks: [Int: CommandBlocks.Block?]) {
        guard blocks.contains(where: { value.entry(id: $0.key)?.block != $0.value }) else { return }
        value.setBlocks(blocks)
    }

    /// Entries the sidebar lists.
    func listed(matching filter: TimelineFilter) -> [TimelineEntry] {
        value.entries(matching: filter).filter { $0.id >= listStart }
    }

    func clearList() {
        guard let last = value.entries.last else { return }
        listStart = last.id + 1
    }

    /// Takes up the commands of an earlier session of the pane.
    func restore(_ timeline: CommandTimeline, listStart: Int) {
        value = timeline
        self.listStart = listStart
    }
}

/// The Commands sidebar, on the right of the window: every command run in the focused pane, with how
/// it ended and what it printed last. Click one to go back to it in the terminal; Space shows its output,
/// even after it has left the scrollback. Switched to All Panes, it lists the commands of every pane in
/// every window, so the filter searches all of their output at once.
final class CommandTimelineSidebar: NSView {
    static let defaultWidth: CGFloat = 280
    static let widthRange: ClosedRange<CGFloat> = 200...560

    /// Whose commands it lists.
    enum Scope: Int {
        /// The focused pane's.
        case pane
        /// Every pane's, in every window, under the pane they ran in.
        case all
    }

    /// A pane, and where it is, for All Panes.
    struct PanePlace {
        let pane: Pane
        /// "Window 2 › api › left": the window when there are several, the tab, and where the pane is
        /// in it when the tab is split.
        let title: String
    }

    let table = TimelineTableView()
    let searchField = NSSearchField()
    let scopeControl = NSSegmentedControl(labels: ["This Pane", "All Panes"], trackingMode: .selectOne,
                                          target: nil, action: nil)
    /// Find's options, Aa, ab and .*, for the filter.
    let toggles = FindOptionToggles()
    /// The user dragged the leading edge to this width.
    var onResize: ((CGFloat) -> Void)?
    /// Save to Intel, on a command from this pane.
    var onSaveToIntel: ((TimelineEntry, Pane?) -> Void)?
    /// What explains failed commands, if Settings allow it.
    var explainer: () -> (any FailureExplaining)? = { nil }
    /// Every pane in every window, in order, for All Panes.
    var places: () -> [PanePlace] = { [] }
    /// Goes to a command listed in All Panes: to its window, tab and pane, to the line that matched,
    /// with Find open there. False when it can't be gone to, as it's no longer in the scrollback.
    var onGoToCommand: ((TimelineEntry, Pane, TimelineFilter) -> Bool)?

    private(set) weak var pane: Pane?
    private(set) var scope = Scope.pane
    private(set) var rows: [Row] = []
    /// The pane each row is from.
    private var rowPanes: [Pane] = []
    private let header: NSHostingView<TimelineHeader>
    private let headerModel = TimelineHeaderModel()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let divider = NSView()
    private let resizeHandle = SidebarResizeHandle()
    private var theme: CodecTheme
    private var codeFont: NSFont
    private var subscription: AnyCancellable?
    /// The panes `subscription` hears from.
    private var observed: [ObjectIdentifier] = []
    private var panesChanged: AnyCancellable?
    private var reloadPending = false
    private var clock: Timer?
    /// Where each pane's scrollback starts, as of the last reload: commands above it are only in the kept output.
    private var scrollbackStarts: [ObjectIdentifier: Int] = [:]
    private var outputPopover: NSPopover?
    /// Whether AppKit is handling a key press; tests stand in for it.
    var handlingKeyPress: () -> Bool = { NSApp.currentEvent?.type == .keyDown }
    /// Set while the list puts the selection back after reloading, which isn't the user moving it.
    private var restoringSelection = false

    enum Row: Equatable {
        /// Where the commands below ran, and with what Python environment and tool versions.
        case directory(String, Toolchain?)
        /// In All Panes, the pane the commands below ran in: where it is, and its folder now.
        case pane(String, directory: String)
        case entry(TimelineEntry)

        var entry: TimelineEntry? {
            if case .entry(let entry) = self { return entry }
            return nil
        }
    }

    init(theme: CodecTheme, codeFont: NSFont) {
        self.theme = theme
        self.codeFont = codeFont
        header = NSHostingView(rootView: TimelineHeader(model: headerModel, theme: theme))
        super.init(frame: .zero)
        headerModel.onChange = { [weak self] in self?.reload() }
        headerModel.onClear = { [weak self] in self?.clearList() }
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func build() {
        wantsLayer = true
        searchField.placeholderString = "Filter commands and output"
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 12)
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.setAccessibilityLabel("Filter commands")
        toggles.onChange = { [weak self] in self?.searchChanged() }
        let options = NSStackView(views: toggles.buttons)
        options.orientation = .horizontal
        options.spacing = 2

        scopeControl.controlSize = .small
        scopeControl.font = .systemFont(ofSize: 11)
        scopeControl.segmentDistribution = .fillEqually
        scopeControl.selectedSegment = Scope.pane.rawValue
        scopeControl.target = self
        scopeControl.action = #selector(scopeChanged)
        scopeControl.setToolTip("Commands run in the focused pane", forSegment: Scope.pane.rawValue)
        scopeControl.setToolTip("Commands run in every pane, in every window (⇧⌘F)", forSegment: Scope.all.rawValue)
        scopeControl.setAccessibilityLabel("Show commands from")

        let column = NSTableColumn(identifier: .init("command"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        // Drawn by TimelineRowView, in the theme's colors.
        table.selectionHighlightStyle = .regular
        table.backgroundColor = .clear
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.doubleAction = #selector(doubleClicked)
        table.menu = NSMenu()
        table.menu?.delegate = self
        table.menu?.autoenablesItems = false
        table.onPrimaryAction = { [weak self] in self?.goToSelected(focusTerminal: true) }
        table.onSpace = { [weak self] in self?.toggleOutputOfSelected() }
        table.onEscape = { [weak self] in self?.focusTerminal() }
        table.onCopy = { [weak self] in self?.selectedEntry.map { self?.copy($0.command) } }
        table.onFind = { [weak self] in self?.window?.makeFirstResponder(self?.searchField) }
        table.setAccessibilityLabel("Commands")

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
            self.onResize?(self.frame.width - delta)
        }

        for view in [header, scopeControl, searchField, options, scrollView, emptyLabel, divider, resizeHandle] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            resizeHandle.topAnchor.constraint(equalTo: topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: bottomAnchor),
            resizeHandle.centerXAnchor.constraint(equalTo: divider.centerXAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 8),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 34),
            scopeControl.topAnchor.constraint(equalTo: header.bottomAnchor),
            scopeControl.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 10),
            scopeControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            searchField.topAnchor.constraint(equalTo: scopeControl.bottomAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: options.leadingAnchor, constant: -4),
            options.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            options.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 28),
            emptyLabel.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 20),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
        ] + toggles.sizeConstraints)
        apply(theme: theme, codeFont: codeFont)
    }

    func apply(theme: CodecTheme, codeFont: NSFont) {
        self.theme = theme
        self.codeFont = codeFont
        header.rootView = TimelineHeader(model: headerModel, theme: theme)
        layer?.backgroundColor = theme.foreground.withAlphaComponent(theme.isDark ? 0.025 : 0.035).cgColor
        divider.layer?.backgroundColor = theme.divider.cgColor
        toggles.apply(accent: theme.accent, dim: .secondaryLabelColor)
        refreshVisibleRows()
    }

    // MARK: Following a pane

    /// Shows a pane's commands. Nil while the sidebar is hidden, so it doesn't track anything. In All
    /// Panes, the list stays as it is: the pane is only where Insert Command and Run Again go.
    func follow(_ pane: Pane?) {
        guard pane !== self.pane || (pane != nil) != (subscription != nil) else { return }
        let listing = subscription != nil
        self.pane = pane
        if scope == .all, pane != nil, listing { return }
        outputPopover?.close()
        subscribe()
        reload(scrollToEnd: true)
    }

    /// Lists the focused pane's commands, or every pane's.
    func setScope(_ scope: Scope) {
        scopeControl.selectedSegment = scope.rawValue
        guard scope != self.scope else { return }
        self.scope = scope
        outputPopover?.close()
        // Panes come and go in other windows too.
        panesChanged = scope == .all ? NotificationCenter.default.publisher(for: Self.panesDidChange)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reloadSoon() } } : nil
        subscribe()
        reload(scrollToEnd: true)
    }

    /// ⇧⌘F: every pane's commands, with the keyboard in the filter.
    func findInAllPanes() {
        setScope(.all)
        window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    /// Posted when panes were opened or closed, in any window.
    static let panesDidChange = Notification.Name("CodecPanesDidChange")

    @objc private func scopeChanged() {
        setScope(Scope(rawValue: scopeControl.selectedSegment) ?? .pane)
    }

    /// Listens to the panes listed for new commands and output.
    private func subscribe(to panes: [Pane]? = nil) {
        let panes = pane == nil ? [] : panes ?? (scope == .pane ? [pane].compactMap { $0 } : listedPlaces().map(\.pane))
        observed = panes.map(ObjectIdentifier.init)
        subscription = pane == nil ? nil : Publishers.MergeMany(panes.map { $0.timeline.objectWillChange })
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
    }

    private func listedPlaces() -> [PanePlace] {
        places().filter { !$0.pane.isShutDown }
    }

    private func reloadSoon() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.reloadPending = false
                self?.reload()
            }
        }
    }

    /// What the list is filtered by: the field, Find's options and ⚠.
    var filter: TimelineFilter {
        TimelineFilter(query: searchField.stringValue, options: toggles.options, failedOnly: headerModel.failedOnly)
    }

    private var query: String { filter.text }

    var selectedEntry: TimelineEntry? { entry(at: table.selectedRow) }

    /// The pane the selected command ran in.
    var selectedPane: Pane? { pane(at: table.selectedRow) }

    /// The row a pane's command is on.
    func row(of entry: TimelineEntry, in pane: Pane) -> Int? {
        rows.indices.first { rows[$0].entry?.id == entry.id && rowPanes[$0] === pane }
    }

    func reload(scrollToEnd: Bool = false) {
        let selected = selectedEntry.flatMap { entry in selectedPane.map { (entry, $0) } }
        let atEnd = scrollToEnd || isScrolledToEnd
        let filter = self.filter
        var rows: [Row] = [], panes: [Pane] = []
        var listed: [Pane] = []
        switch scope {
        case .pane:
            if let pane {
                listed = [pane]
                var context: (directory: String, toolchain: Toolchain?)?
                for entry in pane.timeline.listed(matching: filter) {
                    if context?.directory != entry.directory || context?.toolchain != entry.toolchain {
                        context = (entry.directory, entry.toolchain)
                        rows.append(.directory(entry.directory, entry.toolchain))
                        panes.append(pane)
                    }
                    rows.append(.entry(entry))
                    panes.append(pane)
                }
            }
        case .all:
            let places = pane == nil ? [] : listedPlaces()
            listed = places.map(\.pane)
            if listed.map(ObjectIdentifier.init) != observed { subscribe(to: listed) }
            for place in places {
                let entries = place.pane.timeline.listed(matching: filter)
                guard !entries.isEmpty else { continue }
                rows.append(.pane(place.title, directory: place.pane.session.directory))
                panes.append(place.pane)
                for entry in entries {
                    rows.append(.entry(entry))
                    panes.append(place.pane)
                }
            }
        }
        self.rows = rows
        rowPanes = panes
        scrollbackStarts = [:]
        for pane in listed {
            scrollbackStarts[ObjectIdentifier(pane)] = TerminalGrid(terminal: pane.terminal)?.bufferRowOffset
        }
        headerModel.paneTitle = scope == .pane ? pane?.session.title ?? "" : ""
        headerModel.count = listed.reduce(0) { $0 + $1.timeline.listed(matching: TimelineFilter()).count }
        table.reloadData()
        if let selected, let row = row(of: selected.0, in: selected.1) {
            restoringSelection = true
            table.selectRowIndexes([row], byExtendingSelection: false)
            restoringSelection = false
        }
        if atEnd, !rows.isEmpty { table.scrollRowToVisible(rows.count - 1) }
        updateEmptyState(listed: listed)
        updateClock()
    }

    private var isScrolledToEnd: Bool {
        guard let document = scrollView.documentView else { return true }
        return scrollView.contentView.bounds.maxY >= document.frame.height - 8
    }

    private func updateEmptyState(listed: [Pane]) {
        emptyLabel.isHidden = !rows.isEmpty
        guard rows.isEmpty else { return }
        let all = scope == .all
        if pane == nil {
            emptyLabel.stringValue = ""
        } else if !listed.contains(where: \.session.integrated) {
            emptyLabel.stringValue = "Commands show up here with Codec’s zsh integration (Settings › Shell)."
        } else if headerModel.count == 0 {
            emptyLabel.stringValue = all ? "Commands you run in any pane show up here, with what they printed."
                : "Commands you run in this pane show up here, with what they printed."
        } else if filter.isInvalid {
            emptyLabel.stringValue = "“\(query)” isn’t a valid regular expression."
        } else if query.isEmpty {
            emptyLabel.stringValue = "No failed commands."
        } else {
            emptyLabel.stringValue = all ? "No commands or output in any pane match “\(query)”."
                : "No commands or output match “\(query)”."
        }
    }

    /// Ticks the running commands' elapsed time.
    private func updateClock() {
        let running = rows.contains { $0.entry?.isRunning == true }
        if running, clock == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVisibleRows() }
            }
            RunLoop.main.add(timer, forMode: .common)
            clock = timer
        } else if !running {
            clock?.invalidate()
            clock = nil
        }
    }

    private func refreshVisibleRows() {
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location..<(visible.location + visible.length) where rows.indices.contains(row) {
            guard let view = table.view(atColumn: 0, row: row, makeIfNecessary: false) else { continue }
            configure(view, at: row)
        }
    }

    private func configure(_ view: NSView, at row: Int) {
        switch rows[row] {
        case .directory(let directory, let toolchain):
            (view as? TimelineDirectoryCell)?.show((directory as NSString).abbreviatingWithTildeInPath, toolchain: toolchain,
                                                   theme: theme)
        case .pane(let title, let directory):
            (view as? TimelinePaneCell)?.show(title, directory: (directory as NSString).abbreviatingWithTildeInPath)
        case .entry(let entry):
            guard let cell = view as? TimelineCell else { return }
            let pane = rowPanes[row]
            cell.show(entry, matching: filter.expression, inScrollback: isInScrollback(entry, in: pane), theme: theme,
                      codeFont: codeFont)
            cell.onSave = { [weak self, weak pane] in self?.saveToIntel(entry, from: pane) }
        }
    }

    /// Whether the command can still be scrolled to, as far as can be told without reading the screen.
    func isInScrollback(_ entry: TimelineEntry, in pane: Pane? = nil) -> Bool {
        guard let block = entry.block, !entry.fullScreen else { return false }
        let start = (pane ?? self.pane).flatMap { scrollbackStarts[ObjectIdentifier($0)] }
        return start.map { block.prompt >= $0 } ?? true
    }

    // MARK: Going to commands

    private func entry(at row: Int) -> TimelineEntry? {
        rows.indices.contains(row) ? rows[row].entry : nil
    }

    private func pane(at row: Int) -> Pane? {
        rowPanes.indices.contains(row) ? rowPanes[row] : nil
    }

    /// A click goes to the command in the terminal, or shows its output when it's no longer there.
    @objc private func clicked() {
        let row = table.clickedRow
        guard let entry = entry(at: row), let pane = pane(at: row), NSApp.currentEvent?.clickCount ?? 1 == 1 else { return }
        if !go(to: entry, in: pane) { showOutput(of: entry, in: pane, row: row) }
    }

    @objc private func doubleClicked() {
        let row = table.clickedRow
        guard let entry = entry(at: row) else { return }
        showOutput(of: entry, in: pane(at: row), row: row)
    }

    /// Goes to a command in the terminal: in this pane, or, in All Panes, in its own, wherever that is,
    /// with Find open there.
    @discardableResult
    func go(to entry: TimelineEntry, in pane: Pane? = nil) -> Bool {
        guard let pane = pane ?? self.pane else { return false }
        if scope == .all {
            guard !pane.isShutDown else { return false }
            return onGoToCommand?(entry, pane, filter) ?? false
        }
        let revealed = pane.reveal(entry, matching: filter.expression) != nil
        if !revealed { refreshVisibleRows() }
        return revealed
    }

    /// Return: goes to the selected command and gives the terminal the keyboard (in All Panes, Find
    /// has it, open where the command is).
    func goToSelected(focusTerminal focus: Bool) {
        guard let entry = selectedEntry else { return }
        let pane = selectedPane
        if go(to: entry, in: pane) {
            if focus, scope == .pane { focusTerminal() }
        } else {
            showOutput(of: entry, in: pane, row: table.selectedRow)
        }
    }

    private func toggleOutputOfSelected() {
        if outputPopover?.isShown == true { return outputPopover?.performClose(nil) ?? () }
        guard let entry = selectedEntry else { return }
        showOutput(of: entry, in: selectedPane, row: table.selectedRow)
    }

    func saveToIntel(_ entry: TimelineEntry, from pane: Pane? = nil) {
        outputPopover?.close()
        onSaveToIntel?(entry, pane ?? self.pane)
    }

    func focusTerminal() {
        guard let pane else { return }
        window?.makeFirstResponder(pane.view.preferredResponder)
    }

    /// Selects the newest command and puts the keyboard on the list.
    func focusList() {
        if table.selectedRow < 0, let last = rows.lastIndex(where: { $0.entry != nil }) {
            table.selectRowIndexes([last], byExtendingSelection: false)
            table.scrollRowToVisible(last)
        }
        window?.makeFirstResponder(table)
    }

    // MARK: Output

    var isShowingOutput: Bool { outputPopover?.isShown == true }
    var outputViewer: CommandOutputViewer? { outputPopover?.contentViewController as? CommandOutputViewer }

    /// Opens the output of a command run in `pane` (by default the one followed); with `explain`, starts
    /// explaining why it failed. Insert and Run Again put the command in the focused pane.
    func showOutput(of entry: TimelineEntry, in pane: Pane? = nil, row: Int, explain: Bool = false) {
        guard let pane = pane ?? self.pane, let focused = self.pane, window != nil else { return }
        outputPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        let inScrollback = scope == .all ? isInScrollback(entry, in: pane) && !pane.isShutDown : pane.rows(of: entry) != nil
        let output = pane.output(of: entry)
        let explanation = FailureExplanationModel(entry: entry, output: output, explainer: explainer())
        let viewer = CommandOutputViewer(
            entry: entry, output: output, inScrollback: inScrollback, expression: filter.expression,
            theme: theme, codeFont: codeFont,
            actions: .init(
                goTo: { [weak self, weak popover, weak pane] in
                    popover?.performClose(nil)
                    guard let self, let pane else { return }
                    if self.go(to: entry, in: pane), self.scope == .pane { self.focusTerminal() }
                },
                insert: { [weak self, weak popover] in
                    popover?.performClose(nil)
                    self?.insert(entry.command, run: false)
                },
                run: { [weak self, weak popover] in
                    popover?.performClose(nil)
                    self?.insert(entry.command, run: true)
                },
                close: { [weak popover] in popover?.performClose(nil) },
                saveToIntel: { [weak self, weak pane] in self?.saveToIntel(entry, from: pane) },
                insertCommand: { [weak self, weak popover] command in
                    popover?.performClose(nil)
                    self?.insert(command, run: false)
                }),
            canInsert: focused.isAtCommandLine, explanation: explanation)
        popover.contentViewController = viewer
        outputPopover = popover
        let anchor = row >= 0 && row < table.numberOfRows ? table.rect(ofRow: row) : table.visibleRect
        popover.show(relativeTo: anchor, of: table, preferredEdge: .minX)
        viewer.focusText()
        if explain { explanation.explain() }
    }

    /// Explain Failure, for a failed command when there's something to explain it with.
    private func explainItems(for entry: TimelineEntry, in pane: Pane?, row: Int) -> [NSMenuItem] {
        guard let explainer = explainer(), FailureReport(entry: entry, output: nil) != nil else { return [] }
        return [ClosureMenuItem("Explain Failure", image: "sparkles", enabled: explainer.availability == .available) { [weak self, weak pane] in
            self?.showOutput(of: entry, in: pane, row: row, explain: true)
        }]
    }

    private func insert(_ command: String, run: Bool) {
        guard let pane else { return }
        if pane.replaceCommandLine(with: command, run: run) { focusTerminal() } else { NSSound.beep() }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The bin: hides the commands listed so far (they're still tracked).
    private func clearList() {
        switch scope {
        case .pane: pane?.timeline.clearList()
        case .all: listedPlaces().forEach { $0.pane.timeline.clearList() }
        }
    }

    @objc private func searchChanged() {
        reload(scrollToEnd: true)
    }

    private func clearSearch() {
        searchField.stringValue = ""
        searchChanged()
    }

    /// The row a context menu acts on.
    private var menuRow: Int {
        table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
    }
}

// MARK: - Data source and delegate

extension CommandTimelineSidebar: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view: NSView
        switch rows[row] {
        case .directory:
            view = tableView.makeView(withIdentifier: TimelineDirectoryCell.identifier, owner: nil) ?? TimelineDirectoryCell()
        case .pane:
            view = tableView.makeView(withIdentifier: TimelinePaneCell.identifier, owner: nil) ?? TimelinePaneCell()
        case .entry:
            view = tableView.makeView(withIdentifier: TimelineCell.identifier, owner: nil) ?? TimelineCell()
        }
        configure(view, at: row)
        return view
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: TimelineRowView.identifier, owner: nil) as? TimelineRowView ?? TimelineRowView()
        view.selectionColor = theme.selection
        return view
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .directory: 22
        case .pane: 26
        case .entry: 40
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows[row].entry != nil
    }

    /// Moving through the list with the arrow keys goes to each command in turn. Only then: a key typed in
    /// the terminal is still AppKit's current event when a new command reloads the list. Not in All
    /// Panes, where going to a command can switch tabs and windows.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard scope == .pane, !restoringSelection, window?.firstResponder === table, handlingKeyPress(),
              let entry = selectedEntry else { return }
        go(to: entry)
    }
}

// MARK: - Filter field

extension CommandTimelineSidebar: NSSearchFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            focusList()
            if scope == .pane, let entry = selectedEntry { go(to: entry) }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if table.selectedRow < 0, let last = rows.lastIndex(where: { $0.entry != nil }) {
                table.selectRowIndexes([last], byExtendingSelection: false)
            }
            goToSelected(focusTerminal: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if query.isEmpty { focusTerminal() } else { clearSearch() }
            return true
        default:
            return false
        }
    }
}

// MARK: - Context menu

extension CommandTimelineSidebar: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let entry = entry(at: menuRow) else { return }
        for item in contextMenuItems(for: entry, row: menuRow) {
            menu.addItem(item)
        }
    }

    func contextMenuItems(for entry: TimelineEntry, row: Int) -> [NSMenuItem] {
        let pane = pane(at: row) ?? self.pane
        let output = pane?.liveOutputRange(of: entry)
        let canInsert = self.pane?.isAtCommandLine ?? false
        let hasOutput = output != nil || entry.output != nil
        // In All Panes, the pane may be in a tab that isn't selected, where its rows can't be measured.
        let canGo = scope == .all ? isInScrollback(entry, in: pane) && pane?.isShutDown == false : pane?.rows(of: entry) != nil
        return [
            ClosureMenuItem("Go to Command", image: "arrow.up.left.and.arrow.down.right", enabled: canGo) { [weak self, weak pane] in
                guard let self, let pane else { return }
                if self.go(to: entry, in: pane), self.scope == .pane { self.focusTerminal() }
            },
            ClosureMenuItem("Show Output", image: "text.alignleft", enabled: hasOutput) { [weak self, weak pane] in
                self?.showOutput(of: entry, in: pane, row: row)
            },
        ] + explainItems(for: entry, in: pane, row: row) + [
            .separator(),
            ClosureMenuItem("Save to Intel…", image: "bookmark") { [weak self, weak pane] in self?.saveToIntel(entry, from: pane) },
            .separator(),
            ClosureMenuItem("Copy Command", image: "doc.on.doc") { [weak self] in self?.copy(entry.command) },
            ClosureMenuItem("Copy Output", image: "doc.on.doc.fill", enabled: hasOutput) { [weak self, weak pane] in
                if let text = pane?.output(of: entry) { self?.copy(text) }
            },
            ClosureMenuItem("Select Output", image: "text.line.first.and.arrowtriangle.forward", enabled: output != nil) { [weak self, weak pane] in
                guard let self, let pane, let output = pane.liveOutputRange(of: entry) else { return }
                pane.selectOutput(output)
                self.window?.makeFirstResponder(pane.view.preferredResponder)
            },
            .separator(),
            ClosureMenuItem("Insert Command", image: "text.insert", enabled: canInsert) { [weak self] in
                self?.insert(entry.command, run: false)
            },
            ClosureMenuItem("Run Again", image: "arrow.clockwise", enabled: canInsert) { [weak self] in
                self?.insert(entry.command, run: true)
            },
            .separator(),
            ClosureMenuItem("Copy Folder Path", image: "folder") { [weak self] in self?.copy(entry.directory) },
        ]
    }
}

// MARK: - Header

@MainActor
final class TimelineHeaderModel: ObservableObject {
    @Published var paneTitle = ""
    @Published var count = 0
    @Published var failedOnly = false {
        didSet { onChange() }
    }
    var onChange: () -> Void = {}
    var onClear: () -> Void = {}
}

/// "Commands", the pane they're from, and the list's options.
struct TimelineHeader: View {
    @ObservedObject var model: TimelineHeaderModel
    let theme: CodecTheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Commands")
                .font(.system(size: 12, weight: .semibold))
            if !model.paneTitle.isEmpty {
                Text(model.paneTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            TimelineHeaderButton(systemImage: model.failedOnly ? "exclamationmark.triangle.fill" : "exclamationmark.triangle",
                                 help: model.failedOnly ? "Show All Commands" : "Show Failed Commands Only",
                                 tint: model.failedOnly ? theme.alertColor : nil) {
                model.failedOnly.toggle()
            }
            TimelineHeaderButton(systemImage: "trash", help: "Clear the List") { model.onClear() }
                .disabled(model.count == 0)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(maxHeight: .infinity)
    }
}

private struct TimelineHeaderButton: View {
    let systemImage: String
    let help: String
    var tint: Color?
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
        .foregroundStyle(tint ?? .secondary)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Views

/// The list, with Return, Space, Escape, ⌘C and ⌘F.
final class TimelineTableView: NSTableView {
    var onPrimaryAction: (() -> Void)?
    var onSpace: (() -> Void)?
    var onEscape: (() -> Void)?
    var onCopy: (() -> Void)?
    var onFind: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onPrimaryAction?()  // Return, Enter
        case 49: onSpace?()
        case 53: onEscape?()
        default: super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) { onCopy?() }

    override func performTextFinderAction(_ sender: Any?) { onFind?() }

    @objc func performFindPanelAction(_ sender: Any?) { onFind?() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): selectedRow >= 0
        case #selector(performTextFinderAction(_:)), #selector(performFindPanelAction(_:)): true
        default: super.validateUserInterfaceItem(item)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        return super.menu(for: event)
    }
}

/// A row selected in the theme's selection color, as text is in the terminal, so commands keep their colors.
final class TimelineRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("TimelineRowView")
    var selectionColor: NSColor = .selectedContentBackgroundColor

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override var isSelected: Bool {
        didSet { subviews.compactMap { $0 as? TimelineCell }.forEach { $0.updateSaveButton() } }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        (isEmphasized ? selectionColor : selectionColor.withAlphaComponent(0.6)).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 0), xRadius: 6, yRadius: 6).fill()
    }
}

/// Where the commands below ran, and the Python environment and tool versions they ran with.
final class TimelineDirectoryCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("TimelineDirectoryCell")

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let tools = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 10, weight: .medium)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.lineBreakMode = .byTruncatingHead
        tools.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        tools.lineBreakMode = .byTruncatingTail
        for view in [icon, label, tools] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // The versions give way before the folder, which says where the commands ran.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tools.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        tools.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            tools.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            tools.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            tools.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ directory: String, toolchain: Toolchain? = nil, theme: CodecTheme) {
        label.stringValue = directory
        label.textColor = .secondaryLabelColor
        icon.contentTintColor = .tertiaryLabelColor
        tools.stringValue = toolchain?.shortSummary ?? ""
        tools.textColor = toolchain?.needingAttention.isEmpty == false ? theme.warning : .tertiaryLabelColor
        tools.isHidden = toolchain == nil
        toolTip = [directory, toolchain?.summary].compactMap { $0 }.joined(separator: "\n")
    }

    /// What the heading shows, for tests.
    var shown: (directory: String, tools: String?) { (label.stringValue, tools.isHidden ? nil : tools.stringValue) }

    /// Where the folder and the versions are laid out, and how wide the folder would like to be, for tests.
    var shownFrames: (directory: NSRect, directoryFittingWidth: CGFloat, tools: NSRect) {
        (label.frame, label.fittingSize.width, tools.frame)
    }
}

/// In All Panes, the pane the commands below ran in: where it is ("Window 2 › api › left") and its folder.
final class TimelinePaneCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("TimelinePaneCell")

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let folder = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 10, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        folder.font = .systemFont(ofSize: 11)
        folder.textColor = .secondaryLabelColor
        folder.lineBreakMode = .byTruncatingHead
        for view in [icon, label, folder] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // The folder gives way before where the pane is.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folder.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 3),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            folder.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            folder.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            folder.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ title: String, directory: String) {
        label.stringValue = title
        folder.stringValue = directory
        toolTip = "\(title)\n\(directory)"
        setAccessibilityLabel("\(title), \(directory)")
    }

    /// What the heading shows, for tests.
    var shown: (title: String, directory: String) { (label.stringValue, folder.stringValue) }
}

/// A thin line filled to a fraction, on a faint track of the same color.
final class ProgressLine: NSView {
    private var fraction = 0.0
    private var tint = NSColor.controlAccentColor

    func show(fraction: Double, tint: NSColor) {
        let fraction = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        guard fraction != self.fraction || tint != self.tint else { return }
        self.fraction = fraction
        self.tint = tint
        needsDisplay = true
    }

    var shownFraction: Double { fraction }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        tint.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        tint.setFill()
        var filled = bounds
        filled.size.width *= fraction
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}

/// One command: its status, the command colored as shell code, when it ran and for how long, and the
/// last line it printed (or, while filtering, the line that matched).
final class TimelineCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("TimelineCell")

    private let dot = NSView()
    private let command = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let duration = NSTextField(labelWithString: "")
    private let archived = NSImageView()
    private let saveButton = NSButton()
    /// How far along a running command likely is, from how long it usually takes.
    private let progress = ProgressLine()
    /// Save to Intel, from the button that shows over the row while the mouse is on it.
    var onSave: (() -> Void)?
    private var hovering = false {
        didSet { updateSaveButton() }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        saveButton.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: "Save to Intel")
        saveButton.symbolConfiguration = .init(pointSize: 10.5, weight: .medium)
        saveButton.isBordered = false
        saveButton.bezelStyle = .accessoryBarAction
        saveButton.contentTintColor = .secondaryLabelColor
        saveButton.toolTip = "Save to Intel"
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.isHidden = true
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        for label in [command, detail] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.usesSingleLineMode = true
            label.cell?.wraps = false
        }
        for label in [time, duration] {
            label.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
        }
        archived.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: "Saved output only")
        archived.symbolConfiguration = .init(pointSize: 9, weight: .regular)
        archived.contentTintColor = .tertiaryLabelColor
        archived.toolTip = "No longer in the terminal’s scrollback. Codec kept its output: double-click or press Space to see it."
        archived.setContentCompressionResistancePriority(.required, for: .horizontal)
        progress.isHidden = true
        for view in [dot, command, time, detail, duration, archived, saveButton, progress] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        command.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            dot.centerYAnchor.constraint(equalTo: command.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            command.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            command.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            command.trailingAnchor.constraint(lessThanOrEqualTo: time.leadingAnchor, constant: -6),
            time.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            time.firstBaselineAnchor.constraint(equalTo: command.firstBaselineAnchor),
            progress.leadingAnchor.constraint(equalTo: command.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: time.trailingAnchor),
            progress.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            progress.heightAnchor.constraint(equalToConstant: 2),
            detail.leadingAnchor.constraint(equalTo: command.leadingAnchor),
            detail.topAnchor.constraint(equalTo: command.bottomAnchor, constant: 1),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: archived.leadingAnchor, constant: -4),
            archived.trailingAnchor.constraint(equalTo: duration.leadingAnchor, constant: -4),
            archived.centerYAnchor.constraint(equalTo: duration.centerYAnchor),
            duration.trailingAnchor.constraint(equalTo: time.trailingAnchor),
            duration.firstBaselineAnchor.constraint(equalTo: detail.firstBaselineAnchor),
            // Over the time, while it shows.
            saveButton.centerYAnchor.constraint(equalTo: time.centerYAnchor),
            saveButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            saveButton.widthAnchor.constraint(equalToConstant: 22),
            saveButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    @objc private func save() {
        onSave?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }

    override func mouseExited(with event: NSEvent) { hovering = false }

    func updateSaveButton() {
        let selected = (superview as? NSTableRowView)?.isSelected ?? false
        saveButton.isHidden = !(hovering || selected)
        time.alphaValue = saveButton.isHidden ? 1 : 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ entry: TimelineEntry, matching expression: NSRegularExpression?, inScrollback: Bool, theme: CodecTheme,
              codeFont: NSFont) {
        command.attributedStringValue = ShellHighlighting.attributed(entry.command, theme: theme, font: codeFont, size: 12)
        let calendar = Calendar.current
        time.stringValue = calendar.isDateInToday(entry.started)
            ? entry.started.formatted(date: .omitted, time: .shortened)
            : entry.started.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        time.toolTip = entry.started.formatted(date: .abbreviated, time: .standard)

        let elapsed = entry.duration ?? Date().timeIntervalSince(entry.started)
        duration.stringValue = Formatting.duration(elapsed)
        duration.textColor = entry.isRunning ? theme.accent : .secondaryLabelColor
        duration.toolTip = nil
        progress.isHidden = true
        // How it compares with how long it usually takes.
        var usualText: (text: String, over: Bool)?
        if let usual = entry.usualDuration {
            if entry.isRunning {
                let over = elapsed > usual
                usualText = over ? ("\(Formatting.seconds(elapsed - usual)) over its usual \(Formatting.seconds(usual))", true)
                                 : ("\(Formatting.seconds(usual - elapsed)) left · usually \(Formatting.seconds(usual))", false)
                progress.isHidden = false
                progress.show(fraction: elapsed / usual, tint: over ? theme.warning : theme.accent)
                if over { duration.textColor = theme.warning }
            } else if entry.status == .succeeded, let took = entry.duration {
                let comparison = UsualDuration.Comparison(duration: took, usual: usual)
                switch comparison {
                case .asUsual:
                    duration.toolTip = "As usual: it usually takes \(Formatting.seconds(usual))"
                case .slower:
                    duration.stringValue += " · " + comparison.multiplier
                    duration.textColor = theme.warning
                    duration.toolTip = "\(comparison.multiplier) its usual \(Formatting.seconds(usual))"
                case .faster:
                    duration.toolTip = "Faster than its usual \(Formatting.seconds(usual))"
                }
            }
        }

        var detailText: String
        var detailColor = NSColor.secondaryLabelColor
        let match = expression.flatMap { entry.output?.firstMatch(of: $0) }
        // The line that matched, from a little before the match; the lines around it on hover.
        detail.toolTip = match.map { [$0.before, $0.line, $0.after].compactMap { $0 }.joined(separator: "\n") }
        if let match {
            detailText = match.excerpt()
            detailColor = .labelColor
        } else if entry.isRunning, let usualText, !entry.fullScreen {
            detailText = usualText.text
            if usualText.over { detailColor = theme.warning }
        } else if entry.isRunning {
            detailText = entry.fullScreen ? "Running full screen…" : "Running…"
        } else if entry.fullScreen {
            detailText = "Full-screen program"
            detailColor = .tertiaryLabelColor
        } else if let summary = entry.output?.summary {
            detailText = summary
        } else {
            detailText = "No output"
            detailColor = .tertiaryLabelColor
        }
        if case .failed(let code) = entry.status, code >= 0, match == nil {
            detailText = "Exit \(code) · " + detailText
        }
        detail.stringValue = detailText
        detail.font = NSFont(descriptor: codeFont.fontDescriptor, size: 10.5) ?? .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        detail.textColor = detailColor
        archived.isHidden = inScrollback || entry.isRunning || entry.fullScreen

        let color: NSColor
        switch entry.status {
        case .running: color = theme.accent
        case .succeeded: color = theme.ansi[2]
        case .failed(let code): color = code < 0 ? .tertiaryLabelColor : theme.alert
        }
        dot.layer?.backgroundColor = color.cgColor
        if entry.isRunning {
            if dot.layer?.animation(forKey: "pulse") == nil {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1
                pulse.toValue = 0.25
                pulse.duration = 0.8
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                dot.layer?.add(pulse, forKey: "pulse")
            }
        } else {
            dot.layer?.removeAnimation(forKey: "pulse")
        }
        toolTip = entry.command
        updateSaveButton()
        setAccessibilityLabel(spokenDescription(entry, detail: detailText))
    }

    private func spokenDescription(_ entry: TimelineEntry, detail: String) -> String {
        let status = switch entry.status {
        case .running: "running"
        case .succeeded: "succeeded"
        case .failed(let code): code < 0 ? "ended" : "failed with status \(code)"
        }
        let timing = entry.isRunning ? nil : [duration.stringValue, duration.toolTip].compactMap { $0 }.joined(separator: ", ")
        return [entry.command, status, timing, detail].compactMap { $0 }.joined(separator: ", ")
    }

    /// What the row shows, for tests.
    var shown: (detail: String, duration: String, durationColor: NSColor?, progress: Double?) {
        (detail.stringValue, duration.stringValue, duration.textColor, progress.isHidden ? nil : progress.shownFraction)
    }
}

/// Commands colored as shell code, for AppKit labels.
enum ShellHighlighting {
    static func attributed(_ command: String, theme: CodecTheme, font: NSFont, size: CGFloat,
                           singleLine: Bool = true) -> NSAttributedString {
        let text = singleLine ? command.replacingOccurrences(of: "\n", with: " ⏎ ") : command
        let base = NSFont(descriptor: font.fontDescriptor, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        var attributes: [NSAttributedString.Key: Any] = [.font: base, .foregroundColor: theme.foreground]
        if singleLine {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            attributes[.paragraphStyle] = paragraph
        }
        let attributed = NSMutableAttributedString(string: text, attributes: attributes)
        let length = (text as NSString).length
        for span in SyntaxHighlighter.spans(in: text, language: .shell) where span.location + span.length <= length {
            attributed.addAttribute(.foregroundColor, value: theme.color(for: span.token),
                                    range: NSRange(location: span.location, length: span.length))
        }
        return attributed
    }
}
