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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, AppCoordinating {
    private let environment: AppEnvironment
    private(set) var windows: [TerminalWindowController] = []
    private var settingsWindow: NSWindow?
    /// Nil outside a bundled app with a version (tests, `swift run`).
    private(set) var updater: Updater?
    private var updateProgress: UpdateProgressWindow?
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
                if id == Updater.notificationID {
                    self?.updater?.showAvailable()
                    return
                }
                _ = self?.windows.first { $0.reveal(sessionID: id) }
            }
        }
        if Bundle.main.bundleURL.pathExtension == "app", let version = AppVersion.running {
            let updater = Updater(current: version, preferences: environment.preferences, notifier: environment.notifier)
            updater.present = { [weak self] in self?.showUpdate($0) }
            updater.installationChanged = { [weak self] in self?.showInstallation($0) }
            updater.start()
            self.updater = updater
        }
        if !restoreWindows() { newWindow(nil) }
        NSApp.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        saveWindows(keepingContents: environment.preferences.restorePaneContents)
        updater?.finishInstalling()
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

    /// Saves the windows a moment after they change, once for a burst of changes. Changes while a save
    /// is pending don't put it off: they're in what it saves, and windows that never stop changing (a
    /// pane's command updating its progress) would otherwise never be saved.
    private func scheduleSave() {
        guard !terminating, pendingSave == nil else { return }
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
                                                     history: environment.history,
                                                     venvDecisions: environment.shellIntegration?.venvDecisions,
                                                     updates: updater.map { updater in
                                                         SettingsView.Updates(version: "\(updater.current)") { [weak updater] in
                                                             updater?.checkNow()
                                                         }
                                                     })
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Updates

    @objc func checkForUpdates(_ sender: Any?) {
        updater?.checkNow()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(checkForUpdates(_:)) else { return true }
        if let updater { menuItem.title = updater.menuTitle }
        return updater != nil
    }

    private func showUpdate(_ finding: Updater.Finding) {
        guard let updater else { return }
        NSApp.activate()
        let response = updater.alert(for: finding).runModal()
        switch (finding, response) {
        case (.available(let release), .alertFirstButtonReturn):
            if updater.installedWithHomebrew {
                typeUpgradeCommand()
            } else if updater.installer != nil {
                updater.install(release)
            } else {
                NSWorkspace.shared.open(release.diskImage ?? release.page)
            }
        case (.available(let release), .alertThirdButtonReturn):
            updater.skip(release)
        case (.readyToInstall, .alertFirstButtonReturn):
            // Quitting asks first if programs are still running; if it's cancelled, nothing is installed yet.
            updater.relaunchesAfterInstalling = true
            NSApp.terminate(nil)
            updater.relaunchesAfterInstalling = false
        case (.installFailed(_, _, let download), .alertFirstButtonReturn):
            NSWorkspace.shared.open(download)
        default:
            break
        }
    }

    private func showInstallation(_ installation: Updater.Installation?) {
        guard let installation else {
            updateProgress?.close()
            updateProgress = nil
            return
        }
        if updateProgress == nil {
            updateProgress = UpdateProgressWindow { [weak self] in self?.updater?.cancelInstalling() }
        }
        updateProgress?.show(installation)
    }

    /// Puts Homebrew's upgrade command at the front pane's prompt, or on the clipboard when no shell is
    /// waiting at one.
    private func typeUpgradeCommand() {
        let command = Homebrew.upgradeCommand
        if currentWindow?.typeCommand(command) == true || windows.contains(where: { $0.typeCommand(command) }) { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        let alert = NSAlert()
        alert.messageText = "The upgrade command is on the clipboard"
        alert.informativeText = "No shell is waiting at its prompt. Paste \(command) into one, run it, then reopen Codec."
        alert.runModal()
    }

    // MARK: - AppCoordinating

    func newWindow() { newWindow(nil) }

    func showSettings() { showSettings(nil) }

    func attentionDidChange() {
        let count = windows.flatMap(\.allPanes).filter(\.session.needsAttention).count
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }
}
