import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    private var channels: [ChannelWindowController] = []
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        NSApp.mainMenu = MainMenu.build()
        IncomingCalls.shared.activate()
        IncomingCalls.shared.onAnswer = { [weak self] frequency in
            guard let channel = self?.channels.first(where: { $0.session.frequency == frequency }) else { return }
            NSApp.activate()
            channel.window?.makeKeyAndOrderFront(nil)
        }
        newWindow(nil)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if channels.isEmpty { newWindow(nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = channels.filter(\.hasRunningJob)
        guard !busy.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Abort the mission?"
        alert.informativeText = busy.count == 1
            ? "A process is still running on \(busy[0].session.frequency). Quitting will terminate it."
            : "Processes are still running on \(busy.count) channels. Quitting will terminate them."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    // MARK: - Channels

    private var currentChannel: ChannelWindowController? {
        channels.first { $0.window === NSApp.keyWindow } ?? channels.first { $0.window === NSApp.mainWindow }
    }

    @discardableResult
    private func makeChannel(directory: String?) -> ChannelWindowController {
        let channel = ChannelWindowController(directory: directory)
        channel.onClose = { [weak self] closed in
            self?.channels.removeAll { $0 === closed }
            self?.refreshDockBadge()
        }
        channels.append(channel)
        return channel
    }

    @objc func newWindow(_ sender: Any?) {
        let previous = currentChannel?.window
        let channel = makeChannel(directory: nil)
        guard let window = channel.window else { return }
        if let previous {
            let topLeft = NSPoint(x: previous.frame.minX, y: previous.frame.maxY)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: topLeft))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// New tab in the current window, starting in the same directory.
    @objc func newTab(_ sender: Any?) {
        guard let current = currentChannel, let host = current.window else {
            newWindow(sender)
            return
        }
        let channel = makeChannel(directory: current.session.directory)
        guard let window = channel.window else { return }
        host.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }

    @objc func selectChannel(_ sender: NSMenuItem) {
        guard let window = NSApp.keyWindow else { return }
        let tabs = window.tabbedWindows ?? [window]
        let index = sender.tag == 9 ? tabs.count - 1 : sender.tag - 1
        guard tabs.indices.contains(index) else { return }
        tabs[index].makeKeyAndOrderFront(nil)
    }

    func refreshDockBadge() {
        let calls = channels.filter { $0.session.incoming }.count
        NSApp.dockTile.badgeLabel = calls > 0 ? "\(calls)" : nil
    }

    // MARK: - Panels

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: controller)
            window.title = "Codec Settings"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSMutableAttributedString(
            string: "Tactical terminal operations.\nTune in. Stay hidden.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: {
                    let p = NSMutableParagraphStyle()
                    p.alignment = .center
                    return p
                }(),
            ])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Codec",
            .credits: credits,
        ])
    }
}
