import AppKit
import SwiftTerm
import CodecCore

/// Find in a pane's terminal, in place of SwiftTerm's own find bar: a bar over the pane's top-right corner
/// that counts the matches, every match in view tinted, the current one outlined, and where they all are
/// in the scrollback marked down the pane's right edge.
@MainActor
final class TerminalFinder {
    /// One match: the cells it covers on each row it spans, in scroll-invariant rows.
    struct Match: Equatable {
        struct Run: Equatable {
            var row: Int
            var columns: Range<Int>
        }
        var runs: [Run]
        var row: Int { runs[0].row }
    }

    let bar = FindBar()
    let highlights = FindHighlightView()
    private unowned let terminal: CodecTerminalView
    private(set) var matches: [Match] = []
    private(set) var current: Int?
    /// The rows last searched, top to bottom, to place the marks down the edge.
    private var searchedRows: Range<Int> = 0..<0

    var isOpen: Bool { !bar.isHidden }

    init(terminal: CodecTerminalView) {
        self.terminal = terminal
        bar.isHidden = true
        highlights.isHidden = true
        bar.onQueryChanged = { [weak self] in self?.search(revealing: true) }
        bar.onNext = { [weak self] in self?.step(by: 1) }
        bar.onPrevious = { [weak self] in self?.step(by: -1) }
        bar.onClose = { [weak self] in self?.close() }
    }

    func apply(theme: CodecTheme) {
        highlights.color = theme.accent
        highlights.needsDisplay = true
        bar.apply(theme: theme)
    }

    /// A Find menu item (⌘F, ⌘G, ⇧⌘G, ⌘E) reached the terminal.
    func perform(_ action: NSFindPanelAction) {
        switch action {
        case .showFindPanel:
            open(query: selectedText())
        case .next, .previous:
            guard isOpen else { return open(query: nil) }
            step(by: action == .next ? 1 : -1)
        case .setFindString:
            guard let text = selectedText() else { return }
            Self.findPasteboard = text
            open(query: text)
        default:
            break
        }
    }

    /// Shows the bar with the keyboard in it, searching for `query`, or else for what was searched last.
    func open(query: String?) {
        let wasOpen = isOpen
        if let query {
            bar.query = query
        } else if !wasOpen, let last = Self.findPasteboard {
            bar.query = last
        }
        bar.isHidden = false
        highlights.isHidden = false
        bar.focus()
        if !wasOpen || query != nil { search(revealing: true) }
    }

    /// Shows the bar searching for `query` as `options` say, the current match the first one from `row`
    /// on: where a search of every pane went to.
    func open(query: String, options: FindOptions, from row: Int?) {
        bar.query = query
        bar.options = options
        bar.isHidden = false
        highlights.isHidden = false
        bar.focus()
        search(revealing: true, from: row)
    }

    func close() {
        guard isOpen else { return }
        let hadKeyboard = bar.hasKeyboard
        bar.isHidden = true
        highlights.isHidden = true
        matches = []
        current = nil
        if hadKeyboard { terminal.window?.makeFirstResponder(terminal) }
    }

    /// The terminal printed something or was resized: matches may have come, gone or moved.
    func contentChanged() {
        guard isOpen else { return }
        search(revealing: false)
    }

    /// Searches the whole scrollback. With none current before, the current match is the one nearest the
    /// bottom of the screen. Revealing (the query or the options changed), it stays where it was or moves
    /// to the next match after it, as in a browser while you type, and is scrolled to if it's out of view.
    /// Otherwise (output came in, or the terminal rewrapped its rows and renumbered them) it's the same
    /// match if it's still where it was, else the one at its place in the list.
    private func search(revealing: Bool, from row: Int? = nil) {
        let previous = current.map { (index: $0, start: matches[$0].runs[0]) }
        let query = bar.query
        if !query.isEmpty { Self.findPasteboard = query }
        guard let expression = TextSearch.expression(for: query, options: bar.options),
              let snapshot = terminal.terminalContentSnapshot(region: .history(maximumScrollbackRows: CodecTerminalView.scrollback))
        else {
            matches = []
            current = nil
            bar.show(current: nil, total: 0, invalid: !query.isEmpty)
            refreshHighlights()
            return
        }
        matches = Self.matches(of: expression, in: snapshot.rows)
        if let first = snapshot.rows.first, let last = snapshot.rows.last {
            searchedRows = first.absoluteRow..<(last.absoluteRow + 1)
        }
        if let row, !matches.isEmpty {
            current = matches.firstIndex { $0.row >= row } ?? nearestToScreen()
        } else if let previous, !matches.isEmpty {
            let start = previous.start
            current = revealing
                ? matches.firstIndex { ($0.runs[0].row, $0.runs[0].columns.lowerBound) >= (start.row, start.columns.lowerBound) }
                    ?? nearestToScreen()
                : matches.firstIndex { $0.runs[0] == start } ?? min(previous.index, matches.count - 1)
        } else {
            current = nearestToScreen()
        }
        if revealing { reveal() }
        bar.show(current: current, total: matches.count, invalid: false)
        refreshHighlights()
    }

    private func step(by delta: Int) {
        guard !matches.isEmpty else { return }
        let from = current ?? (delta > 0 ? -1 : matches.count)
        current = ((from + delta) % matches.count + matches.count) % matches.count
        reveal()
        bar.show(current: current, total: matches.count, invalid: false)
        refreshHighlights()
    }

    /// The rows on screen, and what to subtract from a row to scroll to it.
    private func viewport() -> (rows: Range<Int>, bufferRowOffset: Int)? {
        guard let snapshot = terminal.terminalContentSnapshot(region: .viewport),
              let top = snapshot.rows.first?.absoluteRow else { return nil }
        return (top..<(top + snapshot.rows.count), top - terminal.terminalStateSnapshot().viewportRow)
    }

    /// The last match that starts above the bottom of the screen: what was printed most recently, among
    /// what's in view or above it.
    private func nearestToScreen() -> Int? {
        guard !matches.isEmpty else { return nil }
        guard let bottom = viewport()?.rows.upperBound else { return matches.count - 1 }
        return matches.lastIndex { $0.row < bottom } ?? 0
    }

    /// Scrolls the current match to the middle of the screen when it's out of view.
    private func reveal() {
        guard let current, let viewport = viewport() else { return }
        let match = matches[current]
        guard !viewport.rows.contains(match.row) || !viewport.rows.contains(match.runs[match.runs.count - 1].row) else { return }
        terminal.scrollTo(row: max(match.row - viewport.rows.count / 2, 0) - viewport.bufferRowOffset)
    }

    /// Redraws the highlights for what's on screen now.
    func refreshHighlights() {
        guard isOpen, !matches.isEmpty, let grid = TerminalGrid(terminal: terminal) else {
            highlights.update(matches: [], current: [], marks: [], track: .zero)
            return
        }
        let shown = grid.viewportTop..<(grid.viewportTop + grid.rows.count)
        var others: [NSRect] = [], currentRects: [NSRect] = []
        var marks: [FindHighlightView.Mark] = []
        var markedLines = Set<Int>()
        let total = max(searchedRows.count, 1)
        for (index, match) in matches.enumerated() {
            for run in match.runs where shown.contains(run.row) {
                let rect = highlights.convert(grid.frame(row: run.row - grid.viewportTop, columns: run.columns), from: nil)
                if index == current { currentRects.append(rect) } else { others.append(rect) }
            }
            // One mark per thousandth of the scrollback is as fine as the edge can show.
            let position = Double(match.row - searchedRows.lowerBound) / Double(total)
            if index == current || markedLines.insert(Int(position * 1000)).inserted {
                marks.append(.init(position: position, isCurrent: index == current))
            }
        }
        let terminalFrame = highlights.convert(terminal.bounds, from: terminal)
        let track = NSRect(x: terminalFrame.maxX + 1, y: terminalFrame.minY, width: 4, height: terminalFrame.height)
        highlights.update(matches: others, current: currentRects, marks: marks, track: track)
    }

    /// The terminal's selection, when it's on one line, to search for.
    private func selectedText() -> String? {
        guard terminal.selectionActive, let text = terminal.getSelection(), !text.contains("\n"),
              !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return text
    }

    /// The system-wide find string, shared with other apps' Find.
    private static var findPasteboard: String? {
        get { NSPasteboard(name: .find).string(forType: .string) }
        set {
            let pasteboard = NSPasteboard(name: .find)
            guard let newValue, pasteboard.string(forType: .string) != newValue else { return }
            pasteboard.clearContents()
            pasteboard.setString(newValue, forType: .string)
        }
    }

    /// Every match in some rows, top to bottom, soft-wrapped rows searched as one line.
    static func matches(of expression: NSRegularExpression, in rows: [TerminalContentRowSnapshot]) -> [Match] {
        var matches: [Match] = []
        var characters: [Character] = []
        var cells: [(row: Int, columns: Range<Int>)] = []
        func searchLine() {
            defer {
                characters.removeAll(keepingCapacity: true)
                cells.removeAll(keepingCapacity: true)
            }
            for range in TextSearch.matches(of: expression, in: characters) {
                var runs: [Match.Run] = []
                for cell in cells[range] {
                    if let last = runs.last, last.row == cell.row {
                        runs[runs.count - 1].columns = last.columns.lowerBound..<cell.columns.upperBound
                    } else {
                        runs.append(.init(row: cell.row, columns: cell.columns))
                    }
                }
                matches.append(Match(runs: runs))
            }
        }
        for row in rows {
            if !row.isWrapped { searchLine() }
            var column = 0
            for cell in row.cells {
                // A wide character's cell is followed by a zero-width placeholder.
                defer { column += cell.width }
                guard cell.width > 0 else { continue }
                characters.append(cell.text.first ?? " ")
                cells.append((row.absoluteRow, column..<(column + cell.width)))
            }
        }
        searchLine()
        return matches
    }
}

// MARK: - Highlights

/// Tints the matches in view and outlines the current one, over the terminal's text; marks where every
/// match is in the scrollback along a track down the pane's right edge.
final class FindHighlightView: NSView {
    struct Mark {
        /// From the top of the scrollback (0) to its bottom (1).
        var position: Double
        var isCurrent: Bool
    }

    var color: NSColor = .controlAccentColor
    private var matches: [NSRect] = []
    private var current: [NSRect] = []
    private var marks: [Mark] = []
    private var track: NSRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(matches: [NSRect], current: [NSRect], marks: [Mark], track: NSRect) {
        self.matches = matches
        self.current = current
        self.marks = marks
        self.track = track
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        for rect in matches {
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 1), xRadius: 2.5, yRadius: 2.5)
            color.withAlphaComponent(0.22).setFill()
            path.fill()
            color.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        if !current.isEmpty {
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = color.withAlphaComponent(0.8)
            glow.shadowBlurRadius = 6
            glow.set()
            for rect in current {
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: -1.5, dy: 0), xRadius: 3, yRadius: 3)
                color.withAlphaComponent(0.4).setFill()
                path.fill()
                color.setStroke()
                path.lineWidth = 2
                path.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        guard !marks.isEmpty, track.height > 0 else { return }
        for mark in marks.sorted(by: { !$0.isCurrent && $1.isCurrent }) {
            // Bottom-up coordinates: the scrollback's top is at the track's top.
            let y = track.maxY - CGFloat(mark.position) * track.height
            let height: CGFloat = mark.isCurrent ? 4 : 2
            let rect = NSRect(x: track.minX, y: min(max(y - height, track.minY), track.maxY - height),
                              width: track.width, height: height)
            (mark.isCurrent ? color : color.withAlphaComponent(0.5)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }
    }
}

// MARK: - The bar

/// The find bar: what to look for, how many matches and which one is current, the match options,
/// previous and next.
final class FindBar: NSView, NSSearchFieldDelegate {
    var onQueryChanged: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    private let glass = NSGlassEffectView()
    private let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    let toggles = FindOptionToggles()
    private let previousButton = FindBar.button("chevron.up", help: "Previous Match (⇧⌘G)")
    private let nextButton = FindBar.button("chevron.down", help: "Next Match (⌘G)")
    private let closeButton = FindBar.button("xmark", help: "Close (Esc)")
    private var countColor: NSColor = .secondaryLabelColor
    private var alertColor: NSColor = .systemRed
    private var accentColor: NSColor = .controlAccentColor

    var query: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    var options: FindOptions {
        get { toggles.options }
        set { toggles.options = newValue }
    }

    /// Whether the keyboard is in the bar's field.
    var hasKeyboard: Bool {
        guard let editor = field.currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.placeholderString = "Find"
        field.controlSize = .small
        field.font = .systemFont(ofSize: 12)
        field.focusRingType = .none
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.setAccessibilityLabel("Find in terminal")
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        count.alignment = .right
        count.lineBreakMode = .byClipping
        toggles.onChange = { [weak self] in self?.onQueryChanged?() }
        previousButton.target = self
        previousButton.action = #selector(previous)
        nextButton.target = self
        nextButton.action = #selector(next)
        closeButton.target = self
        closeButton.action = #selector(close)

        let stack = NSStackView(views: [field, count] + toggles.buttons + [separator(), previousButton, nextButton, closeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.setCustomSpacing(8, after: field)
        stack.setCustomSpacing(8, after: count)
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 6)
        glass.cornerRadius = 12
        glass.contentView = stack
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate(glass.constraintsFilling(self) + [
            field.widthAnchor.constraint(equalToConstant: 180),
            count.widthAnchor.constraint(equalToConstant: 62),
        ] + toggles.sizeConstraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: CodecTheme) {
        countColor = theme.foreground.withAlphaComponent(0.6)
        alertColor = theme.alert
        accentColor = theme.accent
        count.textColor = count.textColor == alertColor ? alertColor : countColor
        toggles.apply(accent: accentColor, dim: countColor)
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Shows which match is current (zero-based) of how many, or that the pattern isn't valid.
    func show(current: Int?, total: Int, invalid: Bool) {
        count.textColor = countColor
        if invalid {
            count.stringValue = "Bad pattern"
            count.textColor = alertColor
        } else if query.isEmpty {
            count.stringValue = ""
        } else if total == 0 {
            count.stringValue = "No results"
            count.textColor = alertColor
        } else if let current {
            count.stringValue = "\(current + 1) of \(total)"
        } else {
            count.stringValue = "\(total)"
        }
        previousButton.isEnabled = total > 0
        nextButton.isEnabled = total > 0
    }

    /// ⌘G and ⇧⌘G step through the matches while typing (the field's editor would take them otherwise),
    /// and ⌘F selects what's typed.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard hasKeyboard else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
        case ("g", [.command]): onNext?()
        case ("g", [.command, .shift]): onPrevious?()
        case ("f", [.command]): field.currentEditor()?.selectAll(nil)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    func controlTextDidChange(_ notification: Notification) {
        onQueryChanged?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { onPrevious?() } else { onNext?() }
        case #selector(NSResponder.moveDown(_:)): onNext?()
        case #selector(NSResponder.moveUp(_:)): onPrevious?()
        case #selector(NSResponder.cancelOperation(_:)): onClose?()
        default: return false
        }
        return true
    }

    @objc private func next() { onNext?() }
    @objc private func previous() { onPrevious?() }
    @objc private func close() { onClose?() }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.heightAnchor.constraint(equalToConstant: 14).isActive = true
        return line
    }

    private static func button(_ symbol: String, help: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help)!,
                              target: nil, action: nil)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.controlSize = .small
        button.imageScaling = .scaleProportionallyDown
        button.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        button.toolTip = help
        return button
    }
}

/// Find's match options as toggles, Aa, ab and .*, in the find bar and the Commands sidebar's filter.
@MainActor
final class FindOptionToggles: NSObject {
    let caseButton = FindOptionToggles.toggle("Aa", help: "Match Case")
    let wordButton = FindOptionToggles.toggle("ab", help: "Whole Words")
    let regexButton = FindOptionToggles.toggle(".*", help: "Regular Expression")
    /// An option was turned on or off by the user.
    var onChange: (() -> Void)?
    private var accent: NSColor = .controlAccentColor
    private var dim: NSColor = .secondaryLabelColor

    var buttons: [NSButton] { [caseButton, wordButton, regexButton] }

    override init() {
        super.init()
        for button in buttons {
            button.target = self
            button.action = #selector(changed)
        }
        style()
    }

    var options: FindOptions {
        get {
            FindOptions(caseSensitive: caseButton.state == .on, regex: regexButton.state == .on,
                        wholeWord: wordButton.state == .on)
        }
        set {
            caseButton.state = newValue.caseSensitive ? .on : .off
            wordButton.state = newValue.wholeWord ? .on : .off
            regexButton.state = newValue.regex ? .on : .off
            style()
        }
    }

    var sizeConstraints: [NSLayoutConstraint] {
        buttons.flatMap { [$0.widthAnchor.constraint(equalToConstant: 24), $0.heightAnchor.constraint(equalToConstant: 20)] }
    }

    func apply(accent: NSColor, dim: NSColor) {
        self.accent = accent
        self.dim = dim
        style()
    }

    @objc private func changed() {
        style()
        onChange?()
    }

    /// An option that's on shows in the accent, on a tint of it; one that's off is dim.
    private func style() {
        for button in buttons {
            let on = button.state == .on
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: on ? .bold : .medium),
                .foregroundColor: on ? accent : dim,
                .underlineStyle: button === wordButton ? NSUnderlineStyle.single.rawValue : 0,
            ])
            button.layer?.backgroundColor = on ? accent.withAlphaComponent(0.2).cgColor : nil
            button.layer?.borderColor = on ? accent.withAlphaComponent(0.6).cgColor : nil
            button.layer?.borderWidth = on ? 1 : 0
        }
    }

    private static func toggle(_ title: String, help: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.setButtonType(.toggle)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.toolTip = help
        button.setAccessibilityLabel(help)
        return button
    }
}
