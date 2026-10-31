import AppKit
import SwiftTerm

/// SwiftTerm's local-process view, with the bell routed to Codec instead of `NSSound.beep()`.
final class CodecTerminalView: LocalProcessTerminalView {
    var onBell: (() -> Void)?
    private var relay: BellRelay!

    override init(frame: CGRect) {
        super.init(frame: frame)
        relay = BellRelay(base: self)
        terminalDelegate = relay
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    fileprivate func ringBell() {
        onBell?()
    }
}

/// `LocalProcessTerminalView` is its own `terminalDelegate` and inherits the default `bell`, which a
/// subclass can't override. This relay stands in as the delegate, forwards everything to the view,
/// and keeps the bell for itself.
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

/// Counts output batches on SwiftTerm's I/O thread so the main thread can turn them into a signal level.
final class ActivityCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func tick() {
        lock.lock(); count += 1; lock.unlock()
    }

    func drain() -> Int {
        lock.lock(); defer { count = 0; lock.unlock() }
        return count
    }
}

/// Reads the foreground program and working directory of a pty, the way Terminal.app titles its tabs.
enum ProcessInspector {
    static func foregroundProcess(ptyFD: Int32) -> pid_t? {
        guard ptyFD >= 0 else { return nil }
        let pgid = tcgetpgrp(ptyFD)
        return pgid > 0 ? pgid : nil
    }

    static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }
}
