import AppKit
import SwiftUI
import CodecCore

/// Entry point for the executable.
public enum CodecApp {
    @MainActor
    public static func run() {
        let app = NSApplication.shared
        let delegate = AppDelegate(environment: .live())
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, AppCoordinating {
    private let environment: AppEnvironment
    private(set) var windows: [TerminalWindowController] = []
    private var settingsWindow: NSWindow?
    private var pendingSave: DispatchWorkItem?
    /// Quitting: windows going away now aren't being closed by the user, so they stay saved.
    private var terminating = false

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init()
        environment.coordinator = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.mainMenu = MainMenu.build()
        if let notifier = environment.notifier as? Notifier {
            notifier.activate()
            notifier.onOpen = { [weak self] id in
                NSApp.activate()
                _ = self?.windows.first { $0.reveal(sessionID: id) }
            }
        }
        if !restoreWindows() { newWindow(nil) }
        NSApp.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        saveWindows()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if windows.isEmpty { newWindow(nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let unsaved = windows.first(where: \.hasUnsavedFiles) {
            // Ask in that window, then try quitting again.
            unsaved.window?.makeKeyAndOrderFront(nil)
            unsaved.confirmDiscardingUnsavedFiles {
                unsaved.editor.documents.filter(\.isDirty).forEach { $0.revert() }
                NSApp.terminate(nil)
            }
            return .terminateCancel
        }
        var programs: [String] = []
        for window in windows {
            for program in window.runningPrograms where !programs.contains(program) { programs.append(program) }
        }
        guard !programs.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Codec?"
        alert.informativeText = "\(RunningPrograms.list(programs)) \(programs.count == 1 ? "is" : "are") still running. Quitting will terminate \(programs.count == 1 ? "it" : "them")."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    // MARK: - Windows

    private var currentWindow: TerminalWindowController? {
        windows.first { $0.window === NSApp.keyWindow } ?? windows.first { $0.window === NSApp.mainWindow }
    }

    @objc func newWindow(_ sender: Any?) {
        open(makeWindow(restoring: nil))
    }

    private func makeWindow(restoring saved: SavedWindow?) -> TerminalWindowController {
        let controller = TerminalWindowController(directory: nil, environment: environment, restoring: saved)
        controller.onClose = { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
            self?.attentionDidChange()
            self?.scheduleSave()
        }
        controller.onStateChange = { [weak self] in self?.scheduleSave() }
        return controller
    }

    private func open(_ controller: TerminalWindowController, frame: CGRect? = nil) {
        let previous = currentWindow?.window
        windows.append(controller)
        scheduleSave()
        guard let window = controller.window else { return }
        if let frame, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            window.setFrame(frame, display: false)
        } else if let previous {
            let topLeft = NSPoint(x: previous.frame.minX, y: previous.frame.maxY)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: topLeft))
        } else if !window.setFrameUsingName("CodecMainWindow") {
            window.center()
        }
        if windows.count == 1 { window.setFrameAutosaveName("CodecMainWindow") }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Reopening windows

    /// Opens the windows saved last time, if there are any and Settings allow it. Returns whether
    /// it opened any.
    @discardableResult
    func restoreWindows() -> Bool {
        guard environment.preferences.restoreWindows,
              let saved = SavedWorkspace.load(from: environment.preferences.stateDefaults) else { return false }
        // Back to front, so the front one ends up in front.
        for savedWindow in saved.windows.reversed() where !savedWindow.tabs.isEmpty {
            open(makeWindow(restoring: savedWindow), frame: savedWindow.frame)
        }
        return !windows.isEmpty
    }

    /// Saves the windows a moment after they change, once for a burst of changes.
    private func scheduleSave() {
        guard !terminating else { return }
        pendingSave?.cancel()
        let save = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveWindows() } }
        pendingSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: save)
    }

    /// Saves the open windows, front to back.
    func saveWindows() {
        pendingSave?.cancel()
        pendingSave = nil
        let front = NSApp.orderedWindows
        let ordered = windows.sorted { a, b in
            (front.firstIndex { $0 === a.window } ?? .max) < (front.firstIndex { $0 === b.window } ?? .max)
        }
        SavedWorkspace(windows: ordered.map(\.savedState)).save(to: environment.preferences.stateDefaults)
    }

    /// Reaches here when no window is open to take ⌘T.
    @objc func newTab(_ sender: Any?) {
        if let current = currentWindow {
            current.newTab(sender)
        } else {
            newWindow(sender)
        }
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            settingsWindow = SettingsView.makeWindow(preferences: environment.preferences, sounds: environment.sounds,
                                                     history: environment.history)
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - AppCoordinating

    func newWindow() { newWindow(nil) }

    func showSettings() { showSettings(nil) }

    func attentionDidChange() {
        let count = windows.flatMap(\.allPanes).filter(\.session.needsAttention).count
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }
}
