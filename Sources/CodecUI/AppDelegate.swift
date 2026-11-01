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
        saveWindows(keepingContents: environment.preferences.restorePaneContents)
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

    private func makeWindow(restoring saved: SavedWindow?,
                            contents: @escaping (String) -> SavedPaneContents? = { _ in nil }) -> TerminalWindowController {
        let controller = TerminalWindowController(directory: nil, environment: environment, restoring: saved, contents: contents)
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

    /// Opens the windows saved last time, if there are any and Settings allow it, with what their
    /// panes showed if that was kept. Returns whether it opened any.
    @discardableResult
    func restoreWindows() -> Bool {
        let preferences = environment.preferences
        let archive = environment.paneArchive
        // Kept contents are read once: after this, they're in the panes.
        defer { archive.keepOnly([]) }
        guard preferences.restoreWindows, let saved = SavedWorkspace.load(from: preferences.stateDefaults) else { return false }
        let contents: (String) -> SavedPaneContents? = preferences.restorePaneContents ? archive.load : { _ in nil }
        // Back to front, so the front one ends up in front.
        for savedWindow in saved.windows.reversed() where !savedWindow.tabs.isEmpty {
            open(makeWindow(restoring: savedWindow, contents: contents), frame: savedWindow.frame)
        }
        return !windows.isEmpty
    }

    /// ⇧⌘T with no window in front: reopens the tab closed last in a window that's open, or in one of
    /// its own.
    @objc func reopenClosedTab(_ sender: Any?) {
        if let window = currentWindow ?? windows.last { return window.reopenClosedTab(sender) }
        guard let closed = environment.closedTabs.pop() else { return NSSound.beep() }
        open(makeWindow(restoring: SavedWindow(frame: nil, tabs: [closed.tab], selectedTab: 0), contents: { closed.contents[$0] }))
    }

    /// Saves the windows a moment after they change, once for a burst of changes.
    private func scheduleSave() {
        guard !terminating else { return }
        pendingSave?.cancel()
        let save = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveWindows() } }
        pendingSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: save)
    }

    /// Saves the open windows, front to back; with `keepingContents`, what each pane shows too (when
    /// quitting, as that takes a moment).
    func saveWindows(keepingContents: Bool = false) {
        pendingSave?.cancel()
        pendingSave = nil
        let front = NSApp.orderedWindows
        let ordered = windows.sorted { a, b in
            (front.firstIndex { $0 === a.window } ?? .max) < (front.firstIndex { $0 === b.window } ?? .max)
        }
        let archive = environment.paneArchive
        var kept: Set<String> = []
        let saved = ordered.map { window in
            window.savedState { pane in
                guard keepingContents, let contents = pane.savedContents() else { return nil }
                let name = pane.session.id.uuidString
                do {
                    try archive.save(contents, as: name)
                } catch {
                    Log.app.error("Couldn't keep a pane's contents: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
                kept.insert(name)
                return name
            }
        }
        SavedWorkspace(windows: saved).save(to: environment.preferences.stateDefaults)
        if keepingContents { archive.keepOnly(kept) }
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
