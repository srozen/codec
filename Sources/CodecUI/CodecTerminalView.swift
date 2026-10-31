import AppKit
import Synchronization
import SwiftTerm

/// SwiftTerm's local-process view, with the bell routed to Codec and a context menu.
final class CodecTerminalView: LocalProcessTerminalView {
    var onBell: (() -> Void)?
    /// Builds the menu shown on right-click when the running program isn't tracking the mouse.
    var contextMenuProvider: ((NSEvent) -> NSMenu?)?
    private var relay: BellRelay?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let relay = BellRelay(base: self)
        self.relay = relay
        terminalDelegate = relay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        return contextMenuProvider?(event) ?? super.menu(for: event)
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
