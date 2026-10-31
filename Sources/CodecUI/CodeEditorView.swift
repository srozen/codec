import AppKit
import CodecCore

extension CodecTheme {
    /// The color code of a kind is drawn in: the theme's terminal palette, so code looks the same in
    /// the editor, the Markdown preview and the shell.
    func color(for token: SyntaxToken) -> NSColor {
        switch token {
        case .keyword: ansi[5]
        case .type: ansi[6]
        case .function: ansi[4]
        case .string, .code: ansi[2]
        case .number: ansi[11]
        case .constant: ansi[3]
        case .comment, .quote: background.blended(withFraction: 0.5, of: foreground) ?? foreground
        case .attribute, .preprocessor: ansi[9]
        case .property: ansi[12]
        case .variable, .tag: ansi[1]
        case .heading, .listMarker: accent
        case .emphasis, .strong: foreground
        case .link: ansi[4]
        }
    }
}

/// Edits one document's text: line numbers, syntax colors, indentation and comment shortcuts.
final class CodeEditorView: NSView {
    let document: EditorDocument
    let textView: EditorTextView
    private let scrollView = NSScrollView()
    private let gutter: LineNumberGutter
    private var theme: CodecTheme
    private var highlightScheduled = false

    init(document: EditorDocument, theme: CodecTheme, font: NSFont) {
        self.document = document
        self.theme = theme
        let layoutManager = NSLayoutManager()
        document.storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        textView = EditorTextView(frame: .zero, textContainer: container)
        gutter = LineNumberGutter(textView: textView)
        super.init(frame: .zero)

        textView.document = document
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = document.isEditable && document.kind != .otherEncoding
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel(document.name)

        // Prose wraps; code scrolls sideways.
        let wraps = document.kind == .markdown || document.language == .plain
        container.widthTracksTextView = wraps
        textView.isHorizontallyResizable = !wraps
        if !wraps {
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }

        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !wraps
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        gutter.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gutter)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(gutter, selector: #selector(LineNumberGutter.redraw),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: NSText.didChangeNotification, object: textView)
        apply(theme: theme, font: font)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: CodecTheme, font: NSFont) {
        self.theme = theme
        textView.font = font
        textView.textColor = theme.foreground
        textView.typingAttributes = [.font: font, .foregroundColor: theme.foreground]
        let fullRange = NSRange(location: 0, length: document.storage.length)
        document.storage.addAttributes([.font: font, .foregroundColor: theme.foreground], range: fullRange)
        textView.insertionPointColor = theme.accent
        textView.selectedTextAttributes = [.backgroundColor: theme.selection]
        textView.lineHighlight = theme.foreground.withAlphaComponent(theme.isDark ? 0.045 : 0.05)
        // A tab is as wide as the file's indentation.
        let paragraph = NSMutableParagraphStyle()
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        paragraph.defaultTabInterval = space * CGFloat(max(1, document.indentation.unit.count == 1 ? 4 : document.indentation.unit.count))
        paragraph.tabStops = []
        textView.defaultParagraphStyle = paragraph
        document.storage.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)
        gutter.apply(theme: theme, font: font)
        highlight()
    }

    @objc private func textChanged() {
        document.textDidChange()
        scheduleHighlight()
    }

    /// Recolors soon: right away for normal files, less often for big ones.
    private func scheduleHighlight() {
        guard !highlightScheduled else { return }
        highlightScheduled = true
        let delay = document.storage.length > 200_000 ? 0.4 : 0.03
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                self?.highlightScheduled = false
                self?.highlight()
            }
        }
    }

    /// Colors the text with temporary attributes: they're not part of the document, so they don't
    /// touch undo or the saved state.
    func highlight() {
        guard let layoutManager = textView.layoutManager else { return }
        let full = NSRange(location: 0, length: document.storage.length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        guard document.language != .plain else { return }
        for span in SyntaxHighlighter.spans(in: document.storage.string, language: document.language)
        where NSMaxRange(span.range) <= full.length {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: theme.color(for: span.token), forCharacterRange: span.range)
        }
    }

    /// The colors of the text, for tests.
    func color(at location: Int) -> NSColor? {
        textView.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: location, effectiveRange: nil) as? NSColor
    }
}

/// The text view: Return keeps indentation, Tab indents selected lines, ⌘/ comments them.
final class EditorTextView: NSTextView {
    weak var document: EditorDocument?
    var lineHighlight: NSColor = .clear
    var onSelectionChange: (() -> Void)?

    override var undoManager: UndoManager? { document?.undoManager ?? super.undoManager }

    override func insertNewline(_ sender: Any?) {
        guard let document else { return super.insertNewline(sender) }
        let text = string as NSString
        let caret = selectedRange().location
        let lineRange = text.lineRange(for: NSRange(location: caret, length: 0))
        let before = text.substring(with: NSRange(location: lineRange.location, length: caret - lineRange.location))
        insertText(TextEditing.newline(after: before, indentation: document.indentation, language: document.language),
                   replacementRange: selectedRange())
    }

    override func insertTab(_ sender: Any?) {
        guard let document else { return super.insertTab(sender) }
        if selectedLinesSpanMoreThanOne {
            transformSelectedLines { $0.map { $0.isEmpty ? $0 : document.indentation.unit + $0 } }
        } else {
            insertText(document.indentation.unit, replacementRange: selectedRange())
        }
    }

    override func insertBacktab(_ sender: Any?) {
        guard let document else { return super.insertBacktab(sender) }
        transformSelectedLines { $0.map { TextEditing.outdent($0, indentation: document.indentation) } }
    }

    @objc func toggleComment(_ sender: Any?) {
        guard let prefix = document?.language.lineComment else { return NSSound.beep() }
        transformSelectedLines { TextEditing.toggleComment($0, prefix: prefix) }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(toggleComment(_:)) { return isEditable && document?.language.lineComment != nil }
        return super.validateUserInterfaceItem(item)
    }

    private var selectedLinesSpanMoreThanOne: Bool {
        let text = string as NSString
        let range = selectedRange()
        guard range.length > 0 else { return false }
        return text.lineRange(for: NSRange(location: range.location, length: 0)).upperBound < NSMaxRange(range)
    }

    /// Replaces the selected lines through `transform`, as one undoable change, keeping them selected.
    private func transformSelectedLines(_ transform: ([String]) -> [String]) {
        guard isEditable else { return }
        let text = string as NSString
        var range = text.lineRange(for: selectedRange())
        // Don't swallow the newline that ends the last line.
        let original = text.substring(with: range)
        let endsWithNewline = original.hasSuffix("\n")
        if endsWithNewline { range.length -= 1 }
        let lines = text.substring(with: range).components(separatedBy: "\n")
        let replacement = transform(lines).joined(separator: "\n")
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        replaceCharacters(in: range, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: range.location, length: (replacement as NSString).length))
    }

    // The current line, faintly.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer, selectedRange().length == 0, window?.firstResponder === self else { return }
        let text = string as NSString
        let line = text.lineRange(for: NSRange(location: min(selectedRange().location, text.length), length: 0))
        var glyphs = layoutManager.glyphRange(forCharacterRange: line, actualCharacterRange: nil)
        if glyphs.length == 0, layoutManager.numberOfGlyphs > 0 { glyphs = NSRange(location: max(0, layoutManager.numberOfGlyphs - 1), length: 1) }
        var bounds = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        if line.location == text.length, !layoutManager.extraLineFragmentRect.isEmpty { bounds = layoutManager.extraLineFragmentRect }
        bounds.origin.x = 0
        bounds.size.width = self.bounds.width
        bounds.origin.y += textContainerOrigin.y
        lineHighlight.setFill()
        bounds.fill()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
        onSelectionChange?()
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }
}

/// Line numbers beside the text, with the current line's brighter. A view of its own beside the
/// scroll view, following the text as it scrolls.
final class LineNumberGutter: NSView {
    private weak var editor: EditorTextView?
    private var font: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private var color: NSColor = .secondaryLabelColor
    private var currentColor: NSColor = .labelColor
    private var width: NSLayoutConstraint!

    override var isFlipped: Bool { true }

    init(textView: EditorTextView) {
        editor = textView
        super.init(frame: .zero)
        width = widthAnchor.constraint(equalToConstant: 40)
        width.isActive = true
        textView.onSelectionChange = { [weak self] in self?.redraw() }
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged), name: NSText.didChangeNotification, object: textView)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: CodecTheme, font editorFont: NSFont) {
        font = NSFont.monospacedDigitSystemFont(ofSize: max(9, editorFont.pointSize - 2), weight: .regular)
        color = theme.background.blended(withFraction: 0.38, of: theme.foreground) ?? .secondaryLabelColor
        currentColor = theme.background.blended(withFraction: 0.8, of: theme.foreground) ?? .labelColor
        textChanged()
    }

    @objc func redraw() {
        needsDisplay = true
    }

    /// Wide enough for the last line's number.
    @objc private func textChanged() {
        guard let editor else { return }
        let lines = max(1, (editor.string as NSString).components(separatedBy: "\n").count)
        let digits = max(3, String(lines).count)
        let needed = ceil(CGFloat(digits) * ("8" as NSString).size(withAttributes: [.font: font]).width + 20)
        if abs(width.constant - needed) > 0.5 { width.constant = needed }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let editor, let layoutManager = editor.layoutManager, let container = editor.textContainer else { return }
        let text = editor.string as NSString
        let visible = editor.visibleRect
        let characters = layoutManager.characterRange(forGlyphRange: layoutManager.glyphRange(forBoundingRect: visible, in: container),
                                                      actualGlyphRange: nil)
        let caretLine = text.lineRange(for: NSRange(location: min(editor.selectedRange().location, text.length), length: 0)).location
        // Count lines up to the first one on screen.
        var number = 1
        var position = 0
        text.enumerateSubstrings(in: NSRange(location: 0, length: characters.location), options: [.byLines, .substringNotRequired]) { _, _, enclosing, _ in
            number += 1
            position = NSMaxRange(enclosing)
        }
        if position > characters.location { number -= 1; position = text.lineRange(for: NSRange(location: characters.location, length: 0)).location }
        let offset = editor.textContainerOrigin.y - visible.minY
        func label(_ number: Int, in lineRect: NSRect, current: Bool) {
            let string = "\(number)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: current ? currentColor : color]
            let size = string.size(withAttributes: attributes)
            let y = lineRect.minY + offset + (lineRect.height - size.height) / 2
            string.draw(at: NSPoint(x: bounds.width - size.width - 10, y: y), withAttributes: attributes)
        }
        while position < text.length, position <= NSMaxRange(characters) {
            let line = text.lineRange(for: NSRange(location: position, length: 0))
            let glyph = layoutManager.glyphIndexForCharacter(at: line.location)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            label(number, in: lineRect, current: line.location == caretLine)
            number += 1
            position = NSMaxRange(line)
        }
        // The empty line after a final newline.
        if text.length == 0 || text.hasSuffix("\n") {
            let extra = layoutManager.extraLineFragmentRect
            if !extra.isEmpty { label(number, in: extra, current: caretLine == text.length) }
        }
    }
}
