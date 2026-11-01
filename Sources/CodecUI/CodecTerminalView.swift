import AppKit
import Synchronization
import SwiftTerm

/// SwiftTerm's local-process view, with the bell routed to Codec, a context menu, and the hooks that
/// let Codec take over mouse gestures on the command line and adjust selections.
final class CodecTerminalView: LocalProcessTerminalView {
    /// Lines kept above the screen. SwiftTerm's default of 500 is short for a terminal.
    static let scrollback = 10_000

    var onBell: (() -> Void)?
    /// Builds the menu shown on right-click when the running program isn't tracking the mouse.
    var contextMenuProvider: ((NSEvent) -> NSMenu?)?
    /// Offered every press first. Return true to own the gesture: its drags and release then go to
    /// `onOwnedDrag` and `onOwnedRelease`, and the terminal doesn't see them.
    var shouldOwnPress: ((NSEvent) -> Bool)?
    var onOwnedDrag: ((NSEvent) -> Void)?
    var onOwnedRelease: ((NSEvent) -> Void)?
    /// A gesture the terminal handled has ended: its click count, whether it dragged, and where it ended.
    var onRelease: ((_ clicks: Int, _ dragged: Bool, _ point: NSPoint) -> Void)?
    /// Copy and Cut, when Codec has its own selection to act on. Return false to let the terminal copy.
    var onCopy: (() -> Bool)?
    var canCopy: (() -> Bool)?
    var onCut: (() -> Void)?
    var canCut: (() -> Bool)?
    /// Files dropped on the terminal, from Finder or the file tree.
    var onDropFiles: (([URL]) -> Void)?

    private var relay: BellRelay?
    private var owningGesture = false
    private var pressClicks = 1
    private var dragged = false

    override init(frame: CGRect) {
        super.init(frame: frame, font: nil, options: TerminalOptions(scrollback: Self.scrollback))
        let relay = BellRelay(base: self)
        self.relay = relay
        terminalDelegate = relay
        registerForDraggedTypes([.fileURL])
    }

    /// Regression: a pane moved into a new split has no height for a moment. Passed on, the terminal
    /// would shrink to no rows and the shell would redraw its prompt into nothing, leaving a prompt of
    /// several lines on screen twice once it had its real size. The size that follows is the one that
    /// counts.
    override func setFrameSize(_ newSize: NSSize) {
        guard newSize.width >= 1, newSize.height >= 1 else { return }
        super.setFrameSize(newSize)
    }

    // MARK: Dropping files

    private func droppedFiles(_ info: any NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onDropFiles != nil && !droppedFiles(sender).isEmpty ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = droppedFiles(sender)
        guard let onDropFiles, !urls.isEmpty else { return false }
        onDropFiles(urls)
        window?.makeFirstResponder(self)
        return true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        return contextMenuProvider?(event) ?? super.menu(for: event)
    }

    // MARK: Gestures

    override func mouseDown(with event: NSEvent) {
        pressClicks = event.clickCount
        dragged = false
        // Clicking anywhere in a pane focuses it; SwiftTerm's own handling doesn't.
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        if shouldOwnPress?(event) == true {
            owningGesture = true
            return
        }
        owningGesture = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        dragged = true
        if owningGesture {
            onOwnedDrag?(event)
        } else {
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if owningGesture {
            owningGesture = false
            onOwnedRelease?(event)
            return
        }
        super.mouseUp(with: event)
        onRelease?(pressClicks, dragged, event.locationInWindow)
    }

    /// Selects from one window point to another the way a drag would, through the terminal's own
    /// mouse handling (SwiftTerm has no public API to set a selection).
    func selectByDragging(from start: NSPoint, to end: NSPoint) {
        guard let down = syntheticEvent(.leftMouseDown, at: start),
              let drag = syntheticEvent(.leftMouseDragged, at: end),
              let up = syntheticEvent(.leftMouseUp, at: end) else { return }
        super.mouseDown(with: down)
        super.mouseDragged(with: drag)
        super.mouseUp(with: up)
    }

    /// Extends the current selection to a window point, as a Shift-click does.
    func extendSelection(to point: NSPoint) {
        guard let down = syntheticEvent(.leftMouseDown, at: point, modifiers: .shift),
              let up = syntheticEvent(.leftMouseUp, at: point, modifiers: .shift) else { return }
        super.mouseDown(with: down)
        super.mouseUp(with: up)
    }

    private func syntheticEvent(_ type: NSEvent.EventType, at point: NSPoint,
                                modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
    }

    // MARK: Copy and Cut

    override func copy(_ sender: Any) {
        if onCopy?() == true { return }
        super.copy(sender)
    }

    @objc func cut(_ sender: Any?) {
        onCut?()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(cut(_:)):
            return canCut?() ?? false
        case #selector(copy(_:)):
            return selectionActive || canCopy?() == true
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    fileprivate func ringBell() {
        onBell?()
    }
}

/// `LocalProcessTerminalView` is its own `terminalDelegate` and inherits the protocol's default `bell`,
/// which a subclass can't override. This relay stands in as the delegate, forwards everything to the
/// view, and keeps the bell for itself.
@MainActor
private final class BellRelay: TerminalViewDelegate {
    weak var base: CodecTerminalView?

    init(base: CodecTerminalView) {
        self.base = base
    }

    func bell(source: TerminalView) {
        base?.ringBell()
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        base?.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        base?.setTerminalTitle(source: source, title: title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        base?.hostCurrentDirectoryUpdate(source: source, directory: directory)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        base?.send(source: source, data: data)
    }

    func scrolled(source: TerminalView, position: Double) {
        base?.scrolled(source: source, position: position)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        base?.requestOpenLink(source: source, link: link, params: params)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        base?.clipboardCopy(source: source, content: content)
    }

    func clipboardRead(source: TerminalView) -> Data? {
        base?.clipboardRead(source: source)
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        base?.rangeChanged(source: source, startY: startY, endY: endY)
    }

    func programStatusChanged(source: TerminalView, records: [TerminalProgramStatus]) {
        base?.programStatusChanged(source: source, records: records)
    }

    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities {
        base?.kittyClipboardCapabilities(source: source) ?? []
    }

    func kittyClipboardAvailableMimeTypes(source: TerminalView, location: KittyClipboardLocation) -> [String]? {
        base?.kittyClipboardAvailableMimeTypes(source: source, location: location)
    }

    func kittyClipboardRead(source: TerminalView, location: KittyClipboardLocation, mimeType: String) -> KittyClipboardReadResult? {
        base?.kittyClipboardRead(source: source, location: location, mimeType: mimeType)
    }

    func kittyClipboardWrite(source: TerminalView, location: KittyClipboardLocation, content: KittyClipboardWriteContent) -> KittyClipboardWriteResult {
        base?.kittyClipboardWrite(source: source, location: location, content: content) ?? .unsupported
    }

    func kittyClipboardRequestPermission(source: TerminalView, request: KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult {
        base?.kittyClipboardRequestPermission(source: source, request: request) ?? .deny
    }
}

/// Counts output batches on SwiftTerm's I/O thread so the main thread can tell when output arrived.
final class ActivityCounter: Sendable {
    private let count = Mutex(0)

    func tick() {
        count.withLock { $0 += 1 }
    }

    /// The batches since the last drain.
    func drain() -> Int {
        count.withLock { value in
            defer { value = 0 }
            return value
        }
    }
}

/// An `NSMenuItem` that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command,
         image: String? = nil, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        keyEquivalentModifierMask = modifiers
        isEnabled = enabled
        if let image { self.image = NSImage(systemSymbolName: image, accessibilityDescription: nil) }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func fire() {
        handler()
    }
}
