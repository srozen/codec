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
    private var windows: [TerminalWindowController] = []
    private var settingsWindow: NSWindow?

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
        newWindow(nil)
        NSApp.activate()
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
        guard windows.contains(where: \.hasRunningJobs) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Codec?"
        alert.informativeText = "Some panes still have programs running. Quitting will terminate them."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    // MARK: - Windows

    private var currentWindow: TerminalWindowController? {
        windows.first { $0.window === NSApp.keyWindow } ?? windows.first { $0.window === NSApp.mainWindow }
    }

    @objc func newWindow(_ sender: Any?) {
        let previous = currentWindow?.window
        let controller = TerminalWindowController(directory: nil, environment: environment)
        controller.onClose = { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
            self?.attentionDidChange()
        }
        windows.append(controller)
        guard let window = controller.window else { return }
        if let previous {
            let topLeft = NSPoint(x: previous.frame.minX, y: previous.frame.maxY)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: topLeft))
        } else if !window.setFrameUsingName("CodecMainWindow") {
            window.center()
        }
        if windows.count == 1 { window.setFrameAutosaveName("CodecMainWindow") }
        window.makeKeyAndOrderFront(nil)
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
            settingsWindow = SettingsView.makeWindow(preferences: environment.preferences, sounds: environment.sounds)
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
