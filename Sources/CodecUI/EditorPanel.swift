import AppKit
import SwiftUI
import PDFKit
import Combine
import CodecCore

/// The editor beside the terminal: tabs for the open files, and the selected one shown as code,
/// rendered Markdown (or both), an image or a PDF.
final class EditorPanel: NSView {
    let model: EditorModel
    /// Opens a file linked from a Markdown preview.
    var openFile: ((URL) -> Void)?
    /// The user dragged the trailing edge to this width.
    var onResize: ((CGFloat) -> Void)?

    private let header: NSHostingView<EditorHeader>
    private let content = NSView()
    private let divider = NSView()
    private let resizeHandle = SidebarResizeHandle()
    private var theme: CodecTheme
    private var font: NSFont
    private var views: [UUID: DocumentViews] = [:]
    private var shown: (id: UUID, mode: EditorDocument.Mode, kind: EditorDocument.Kind)?
    private var cancellables: Set<AnyCancellable> = []
    private var documentObservers: [UUID: AnyCancellable] = [:]

    /// The views made for one document, kept while it's open so switching tabs keeps scroll and undo.
    private struct DocumentViews {
        var editor: CodeEditorView?
        var preview: MarkdownPreviewView?
        var other: NSView?
    }

    init(model: EditorModel, theme: CodecTheme, font: NSFont) {
        self.model = model
        self.theme = theme
        self.font = font
        header = NSHostingView(rootView: EditorHeader(model: model, theme: theme))
        super.init(frame: .zero)
        wantsLayer = true
        divider.wantsLayer = true
        resizeHandle.onDrag = { [weak self] delta in
            guard let self else { return }
            self.onResize?(self.frame.width + delta)
        }
        for view in [header, content, divider, resizeHandle] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: divider.leadingAnchor),
            content.topAnchor.constraint(equalTo: header.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: divider.leadingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            resizeHandle.topAnchor.constraint(equalTo: topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: bottomAnchor),
            resizeHandle.centerXAnchor.constraint(equalTo: divider.centerXAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 8),
        ])
        model.$selectedID.combineLatest(model.$documents)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
            .store(in: &cancellables)
        apply(theme: theme, font: font)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: CodecTheme, font: NSFont) {
        self.theme = theme
        self.font = font
        header.rootView = EditorHeader(model: model, theme: theme)
        divider.layer?.backgroundColor = theme.divider.cgColor
        for views in self.views.values {
            views.editor?.apply(theme: theme, font: font)
            views.preview?.apply(theme: theme, codeFont: font)
        }
    }

    // MARK: Showing the selected document

    var currentEditor: CodeEditorView? { model.selectedID.flatMap { views[$0]?.editor } }
    var currentPreview: MarkdownPreviewView? { model.selectedID.flatMap { views[$0]?.preview } }

    /// Shows the selected document. Runs on its own after the model changes; call it to see the
    /// result right away.
    func update() {
        // Forget views of closed documents.
        let open = Set(model.documents.map(\.id))
        for id in views.keys where !open.contains(id) {
            views[id] = nil
            documentObservers[id] = nil
        }
        guard let document = model.selected else {
            content.subviews.forEach { $0.removeFromSuperview() }
            shown = nil
            return
        }
        observe(document)
        guard shown?.id != document.id || shown?.mode != document.mode || shown?.kind != document.kind else { return }
        let wasFocused = window?.firstResponder.map { ($0 as? NSView)?.isDescendant(of: content) ?? false } ?? false
        content.subviews.forEach { $0.removeFromSuperview() }
        let view = makeView(for: document)
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate(view.constraintsFilling(content))
        shown = (document.id, document.mode, document.kind)
        if wasFocused { focus() }
    }

    private func observe(_ document: EditorDocument) {
        guard documentObservers[document.id] == nil else { return }
        documentObservers[document.id] = document.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self, weak document] _ in
                MainActor.assumeIsolated {
                    guard let self, let document else { return }
                    if self.model.selectedID == document.id { self.update() }
                    self.views[document.id]?.preview?.documentChanged()
                    if document.kind == .image || document.kind == .pdf { self.reloadOther(document) }
                }
            }
    }

    private func makeView(for document: EditorDocument) -> NSView {
        var cached = views[document.id] ?? DocumentViews()
        defer { views[document.id] = cached }
        func editor() -> CodeEditorView {
            if let editor = cached.editor { return editor }
            let editor = CodeEditorView(document: document, theme: theme, font: font)
            cached.editor = editor
            return editor
        }
        func preview() -> MarkdownPreviewView {
            if let preview = cached.preview { return preview }
            let preview = MarkdownPreviewView(document: document, theme: theme, codeFont: font)
            preview.openFile = { [weak self] url in self?.openFile?(url) }
            cached.preview = preview
            return preview
        }
        switch document.kind {
        case .text, .otherEncoding:
            return editor()
        case .markdown:
            switch document.mode {
            case .source: return editor()
            case .preview: return preview()
            case .split:
                return SideBySide(left: editor(), right: preview(), divider: theme.divider)
            }
        case .image, .pdf:
            if let other = cached.other { return other }
            let view = document.kind == .image ? ImagePreview(url: document.url) as NSView : makePDFView(document.url)
            cached.other = view
            return view
        case .binary, .tooLarge, .unreadable:
            return NSHostingView(rootView: UnsupportedFileView(document: document))
        }
    }

    private func reloadOther(_ document: EditorDocument) {
        if let image = views[document.id]?.other as? ImagePreview { image.reload() }
        if let pdf = views[document.id]?.other as? PDFView { pdf.document = PDFDocument(url: document.url) }
    }

    private func makePDFView(_ url: URL) -> PDFView {
        let view = PDFView()
        view.document = PDFDocument(url: url)
        view.autoScales = true
        view.backgroundColor = .clear
        return view
    }

    /// Puts the keyboard in the editor (or the preview).
    func focus() {
        guard let document = model.selected else { return }
        if let editor = views[document.id]?.editor, editor.superview != nil || editor.isDescendant(of: content) {
            window?.makeFirstResponder(editor.textView)
        } else if let preview = views[document.id]?.preview {
            window?.makeFirstResponder(preview.webView)
        } else if let other = views[document.id]?.other {
            window?.makeFirstResponder(other)
        }
    }

    /// Whether the keyboard is in the editor.
    var hasFocus: Bool {
        guard let view = window?.firstResponder as? NSView else { return false }
        return view.isDescendant(of: self)
    }
}

// MARK: - Header

struct EditorHeader: View {
    @ObservedObject var model: EditorModel
    let theme: CodecTheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(model.documents) { document in
                            EditorTab(document: document, selected: document.id == model.selectedID, theme: theme,
                                      select: { model.select(document) }, close: { model.close(document) })
                        }
                    }
                    .padding(.horizontal, 6)
                }
                if let selected = model.selected {
                    DocumentControls(document: selected, theme: theme)
                }
            }
            .frame(height: 34)
            if let selected = model.selected {
                DocumentBanner(document: selected, theme: theme, close: { model.close(selected) })
            }
            Rectangle().fill(theme.dividerColor).frame(height: 1)
        }
    }
}

private struct EditorTab: View {
    @ObservedObject var document: EditorDocument
    let selected: Bool
    let theme: CodecTheme
    var select: () -> Void
    var close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(nsImage: FileIcons.image(for: FileType.of(fileNamed: document.name), theme: theme))
            Text(document.name)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .italic(!document.isPinned)
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
            ZStack {
                if document.isDirty && !hovering {
                    Circle().fill(theme.foregroundColor.opacity(0.7)).frame(width: 7, height: 7)
                } else {
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .opacity(hovering || selected ? 1 : 0)
                    .help("Close (⌘W)")
                }
            }
            .frame(width: 14, height: 14)
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(selected ? 0.09 : hovering ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .simultaneousGesture(TapGesture(count: 2).onEnded { document.isPinned = true })
        .onHover { hovering = $0 }
        .help(document.url.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(document.name + (document.isDirty ? ", edited" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The mode switch for Markdown, and opening the file in its app.
private struct DocumentControls: View {
    @ObservedObject var document: EditorDocument
    let theme: CodecTheme

    var body: some View {
        HStack(spacing: 6) {
            if document.kind == .markdown {
                Picker("Show", selection: $document.mode) {
                    ForEach(EditorDocument.Mode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("Show the source, the rendered page, or both (⇧⌘V)")
            }
            Button {
                NSWorkspace.shared.open(document.url)
            } label: {
                Image(systemName: "arrow.up.forward.app").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open in Default App")
        }
        .padding(.trailing, 10)
    }
}

/// Says when the file changed or vanished under unsaved edits.
private struct DocumentBanner: View {
    @ObservedObject var document: EditorDocument
    let theme: CodecTheme
    var close: () -> Void

    var body: some View {
        if document.isMissing || document.changedOnDisk || document.kind == .otherEncoding {
            HStack(spacing: 8) {
                Image(systemName: document.kind == .otherEncoding ? "lock" : "exclamationmark.triangle.fill")
                    .foregroundStyle(document.kind == .otherEncoding ? Color.secondary : theme.alertColor)
                Text(message).font(.callout)
                Spacer()
                if document.changedOnDisk {
                    Button("Reload") { document.revert() }
                    Button("Keep Mine") { try? document.save() }
                } else if document.isMissing {
                    Button("Save Again") { try? document.save() }.disabled(!document.isEditable)
                    Button("Close", action: close)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(theme.alertColor.opacity(document.kind == .otherEncoding ? 0 : 0.08))
        }
    }

    private var message: String {
        if document.isMissing { return "This file was deleted or moved." }
        if document.changedOnDisk { return "This file changed on disk while you were editing it." }
        return "This file isn’t UTF-8, so it’s read-only."
    }
}

/// For files Codec doesn't show: binaries, very large or unreadable files.
private struct UnsupportedFileView: View {
    let document: EditorDocument

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: document.url.path))
                .resizable()
                .frame(width: 64, height: 64)
            Text(document.name).font(.headline)
            Text(reason).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Open in Default App") { NSWorkspace.shared.open(document.url) }
                .controlSize(.regular)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var reason: String {
        switch document.kind {
        case .binary: "This is a binary file."
        case .tooLarge(let size): "This file is too large to show (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))."
        case .unreadable(let message): message
        default: ""
        }
    }
}

/// Two views in equal halves, with a hairline between them: source and preview.
final class SideBySide: NSView {
    init(left: NSView, right: NSView, divider color: NSColor) {
        super.init(frame: .zero)
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = color.cgColor
        for view in [left, divider, right] {
            view.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor),
            left.topAnchor.constraint(equalTo: topAnchor),
            left.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            right.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor),
            right.topAnchor.constraint(equalTo: topAnchor),
            right.bottomAnchor.constraint(equalTo: bottomAnchor),
            left.widthAnchor.constraint(equalTo: right.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// An image, fitted to the panel and zoomable.
final class ImagePreview: NSView {
    private let url: URL
    private let scrollView = NSScrollView()
    private let imageView = NSImageView()

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.animates = true
        scrollView.documentView = imageView
        scrollView.drawsBackground = false
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.25
        scrollView.maxMagnification = 8
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate(scrollView.constraintsFilling(self) + [
            imageView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
        ])
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var image: NSImage? { imageView.image }

    func reload() {
        imageView.image = NSImage(contentsOf: url)
        imageView.setAccessibilityLabel("Image \(url.lastPathComponent)")
    }
}
