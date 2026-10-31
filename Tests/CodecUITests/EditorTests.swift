import Testing
import AppKit
import CodecCore
@testable import CodecUI

/// A folder of files for the editor to open.
@MainActor
private final class Files {
    let env: TestEnvironment
    init() throws { env = try TestEnvironment() }

    @discardableResult
    func write(_ name: String, _ contents: String) throws -> URL {
        let url = env.directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
}

@Suite("Editor documents", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct EditorDocumentTests {
    @Test func loadsEditsAndSaves() throws {
        let files = try Files()
        defer { files.env.tearDown() }
        let url = try files.write("main.swift", "struct A {\n  let x = 1\n}\n")
        let document = EditorDocument(url: url)
        #expect(document.kind == .text)
        #expect(document.language == .swift)
        #expect(document.indentation == .spaces(2))
        #expect(!document.isDirty)

        document.storage.replaceCharacters(in: NSRange(location: 0, length: 6), with: "class")
        document.textDidChange()
        #expect(document.isDirty)
        #expect(document.isPinned)  // Editing keeps a preview tab.
        try document.save()
        #expect(!document.isDirty)
        #expect(files.read(url) == "class A {\n  let x = 1\n}\n")

        document.storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "enum")
        document.textDidChange()
        document.revert()
        #expect(document.text == "class A {\n  let x = 1\n}\n")
        #expect(!document.isDirty)
    }

    @Test func followsTheDisk() async throws {
        let files = try Files()
        defer { files.env.tearDown() }
        let url = try files.write("notes.txt", "one")
        let document = EditorDocument(url: url)
        // Replaced by another editor, the way most save.
        try files.write("notes.txt", "two")
        #expect(await waitUntil { document.text == "two" })
        #expect(!document.changedOnDisk)

        document.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "mine ")
        document.textDidChange()
        try files.write("notes.txt", "three")
        #expect(await waitUntil { document.changedOnDisk })
        #expect(document.text == "mine two")

        try FileManager.default.removeItem(at: url)
        #expect(await waitUntil { document.isMissing })
    }

    @Test func recognizesWhatItCantEdit() throws {
        let files = try Files()
        defer { files.env.tearDown() }
        let binary = files.env.directory.appendingPathComponent("blob.bin")
        try Data([0, 1, 2, 3]).write(to: binary)
        #expect(EditorDocument(url: binary).kind == .binary)

        let png = files.env.directory.appendingPathComponent("dot.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: png)
        #expect(EditorDocument(url: png).kind == .image)

        let latin = files.env.directory.appendingPathComponent("old.txt")
        try Data([0x63, 0x61, 0x66, 0xE9]).write(to: latin)
        let old = EditorDocument(url: latin)
        #expect(old.kind == .otherEncoding)
        #expect(!old.isEditable)

        let markdown = EditorDocument(url: try files.write("README.md", "# Hi"))
        #expect(markdown.kind == .markdown)
        #expect(markdown.mode == .preview)
        // SVG is XML to edit.
        #expect(EditorDocument(url: try files.write("logo.svg", "<svg/>")).kind == .text)
    }
}

@Suite("Editor tabs", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct EditorModelTests {
    @Test func previewTabsGiveWayToTheNextFile() throws {
        let files = try Files()
        defer { files.env.tearDown() }
        let a = try files.write("a.txt", "a"), b = try files.write("b.txt", "b"), c = try files.write("c.txt", "c")
        let model = EditorModel()
        model.open(a, pin: false)
        model.open(b, pin: false)
        #expect(model.documents.map(\.name) == ["b.txt"])
        model.open(b, pin: true)
        model.open(c, pin: false)
        #expect(model.documents.map(\.name) == ["b.txt", "c.txt"])
        #expect(model.selected?.name == "c.txt")
        model.open(b, pin: false)
        #expect(model.selected?.name == "b.txt")
        #expect(model.documents.count == 2)
        model.selectTab(offset: 1)
        #expect(model.selected?.name == "c.txt")
    }

    @Test func asksBeforeClosingUnsavedWork() throws {
        let files = try Files()
        defer { files.env.tearDown() }
        let model = EditorModel()
        let document = model.open(try files.write("a.txt", "a"), pin: true)
        document.storage.replaceCharacters(in: NSRange(location: 1, length: 0), with: "!")
        document.textDidChange()
        var asked = 0
        model.confirmClose = { _, done in asked += 1; done(false) }
        model.close(document)
        #expect(asked == 1)
        #expect(model.documents.count == 1)
        model.confirmClose = { _, done in done(true) }
        model.close(document)
        #expect(model.documents.isEmpty)
        #expect(model.selected == nil)
    }
}

@Suite("Code editor", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct CodeEditorTests {
    private func editor(_ name: String, _ text: String, files: Files) throws -> (CodeEditorView, NSWindow) {
        let document = EditorDocument(url: try files.write(name, text))
        let view = CodeEditorView(document: document, theme: .codec, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let window = makeTestWindow(size: NSSize(width: 600, height: 400))
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        window.makeFirstResponder(view.textView)
        return (view, window)
    }

    @Test func colorsSyntaxWithoutTouchingTheDocument() throws {
        let files = try Files()
        defer { files.env.tearDown() }
        let (view, window) = try editor("a.swift", "let name = \"codec\" // hi", files: files)
        defer { window.close() }
        #expect(view.color(at: 0) == CodecTheme.codec.color(for: .keyword))
        #expect(view.color(at: 12) == CodecTheme.codec.color(for: .string))
        #expect(view.color(at: 20) == CodecTheme.codec.color(for: .comment))
        #expect(!view.document.isDirty)
        #expect(view.textView.undoManager?.canUndo == false)
    }

    @Test func typingMarksItEditedAndRecolors() async throws {
        let files = try Files()
        defer { files.env.tearDown() }
        let (view, window) = try editor("a.swift", "x", files: files)
        defer { window.close() }
        view.textView.setSelectedRange(NSRange(location: 1, length: 0))
        view.textView.insertText("\nreturn 1", replacementRange: view.textView.selectedRange())
        #expect(view.document.isDirty)
        #expect(await waitUntil { view.color(at: 2) == CodecTheme.codec.color(for: .keyword) })
        view.textView.undoManager?.undo()
        #expect(view.document.text == "x")
    }

    @Test func returnIndentsTabIndentsLinesAndCommentsToggle() throws {
        let files = try Files()
        defer { files.env.tearDown() }
        let (view, window) = try editor("a.swift", "func f() {", files: files)
        defer { window.close() }
        let text = view.textView
        text.setSelectedRange(NSRange(location: 10, length: 0))
        text.insertNewline(nil)
        #expect(view.document.text == "func f() {\n    ")
        text.insertText("a()\nb()", replacementRange: text.selectedRange())
        text.setSelectedRange(NSRange(location: 15, length: 7))
        text.toggleComment(nil)
        // The marker goes at the shallowest line's indentation.
        #expect(view.document.text == "func f() {\n//     a()\n// b()")
        text.toggleComment(nil)
        text.insertTab(nil)
        #expect(view.document.text == "func f() {\n        a()\n    b()")
        text.insertBacktab(nil)
        #expect(view.document.text == "func f() {\n    a()\nb()")
    }
}

@Suite("Markdown preview", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MarkdownPreviewTests {
    @Test func rendersAndFollowsEdits() async throws {
        let files = try Files()
        defer { files.env.tearDown() }
        let document = EditorDocument(url: try files.write("README.md", "# Title\n\n```swift\nlet x = 1\n```"))
        let preview = MarkdownPreviewView(document: document, theme: .codec, codeFont: .monospacedSystemFont(ofSize: 13, weight: .regular))
        #expect(preview.renderedBody.contains("<h1 id=\"title\">Title</h1>"))
        #expect(preview.renderedBody.contains("hl-keyword"))
        document.storage.append(NSAttributedString(string: "\n\n**more**"))
        document.textDidChange()
        preview.documentChanged()
        #expect(await waitUntil { preview.renderedBody.contains("<strong>more</strong>") })
    }

    @Test func pagesAreStyledFromTheTheme() {
        let page = MarkdownPreviewView.page(body: "<p>x</p>", theme: .codec, codeFont: .monospacedSystemFont(ofSize: 13, weight: .regular))
        #expect(page.contains(".hl-keyword { color:"))
        #expect(page.contains("color-scheme: dark"))
        #expect(page.contains("<div id=\"content\"><p>x</p></div>"))
    }

    @Test func mapsLocalFilesToItsSchemeAndBack() {
        let file = URL(fileURLWithPath: "/tmp/some dir/a b.png")
        let url = MarkdownPreviewView.url(for: file)
        #expect(url?.scheme == MarkdownPreviewView.scheme)
        #expect(url.flatMap(MarkdownPreviewView.fileURL(for:))?.path == "/tmp/some dir/a b.png")
        let relative = URL(string: "img/logo.png", relativeTo: MarkdownPreviewView.url(for: URL(fileURLWithPath: "/repo"), directory: true))
        #expect(relative.flatMap { MarkdownPreviewView.fileURL(for: $0.absoluteURL) }?.path == "/repo/img/logo.png")
    }
}

@Suite("Editor in a window", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct EditorWindowTests {
    private func makeWindow(_ env: TestEnvironment) -> TerminalWindowController {
        let controller = TerminalWindowController(directory: env.directory.path, environment: env.environment)
        controller.window?.setContentSize(NSSize(width: 1200, height: 700))
        controller.window?.layoutIfNeeded()
        return controller
    }

    @Test func opensBesideTheTerminalAndCloses() throws {
        let files = try Files()
        defer { files.env.tearDown() }
        let controller = makeWindow(files.env)
        defer { controller.window?.close() }
        #expect(controller.editorPanel.isHidden)
        let terminalWidth = controller.paneContainer.frame.width

        controller.openFile(try files.write("a.swift", "let a = 1"), pin: false, focus: true)
        controller.window?.layoutIfNeeded()
        #expect(!controller.editorPanel.isHidden)
        #expect(controller.editorPanel.frame.width > 280)
        #expect(controller.paneContainer.frame.width < terminalWidth)
        #expect(controller.editorPanel.currentEditor != nil)
        #expect(controller.editorPanel.hasFocus)

        // ⌘W closes the file while the editor has the keyboard, not the pane.
        controller.closePane(nil)
        controller.window?.layoutIfNeeded()
        #expect(controller.editor.documents.isEmpty)
        #expect(controller.editorPanel.isHidden)
        #expect(controller.model.tabs.count == 1)
    }

    @Test func savesAndValidatesCommands() throws {
        let files = try Files()
        defer { files.env.tearDown() }
        let controller = makeWindow(files.env)
        defer { controller.window?.close() }
        let url = try files.write("README.md", "# Hi")
        controller.openFile(url, pin: true, focus: false)
        let document = try #require(controller.editor.selected)
        #expect(controller.editorPanel.currentPreview != nil)
        #expect(controller.validateMenuItem(NSMenuItem(title: "", action: #selector(TerminalWindowController.toggleMarkdownPreview(_:)), keyEquivalent: "")))

        controller.toggleMarkdownPreview(nil)
        #expect(document.mode == .source)
        let editor = try #require(controller.editorPanel.currentEditor)
        editor.textView.setSelectedRange(NSRange(location: 4, length: 0))
        editor.textView.insertText(" there", replacementRange: editor.textView.selectedRange())
        #expect(controller.hasUnsavedFiles)
        controller.saveDocument(nil)
        #expect(files.read(url) == "# Hi there")
        #expect(!controller.hasUnsavedFiles)
        #expect(controller.paletteCommands().contains { $0.id == "markdown-split" })
    }

    @Test func clickingAFileInTheTreePreviewsIt() throws {
        let files = try Files()
        defer { files.env.tearDown() }
        try files.write("one.txt", "1")
        try files.write("two.txt", "2")
        let controller = makeWindow(files.env)
        defer { controller.window?.close() }
        controller.setFileTreeVisible(true)
        let actions = controller.sidebar.actions
        actions.preview(files.env.directory.appendingPathComponent("one.txt"))
        actions.preview(files.env.directory.appendingPathComponent("two.txt"))
        #expect(controller.editor.documents.map(\.name) == ["two.txt"])
        #expect(controller.editor.selected?.isPinned == false)
        actions.open(files.env.directory.appendingPathComponent("one.txt"))
        #expect(controller.editor.documents.map(\.name) == ["two.txt", "one.txt"])
        #expect(controller.editor.selected?.isPinned == true)
    }
}
