import AppKit
import CodecCore

/// A port some pane's program is listening on, and where that pane is: what Window › Listening Ports
/// and the command palette list.
@MainActor
struct PortLocation {
    let port: ListeningPort
    let pane: Pane
    /// "Tab 2 › left pane".
    let place: String

    /// ":3000  node — Tab 2 › left pane", with the name the process was given in place of its program's.
    var title: String { "\(port.label)  \(port.displayName) — \(place)" }

    func goToPane() {
        pane.host?.reveal(pane)
    }

    func openInBrowser() {
        pane.open(port)
    }
}

/// The ports listened on in one window's panes.
@MainActor
struct ListeningWindow {
    let host: (any PaneHost)?
    /// What the window is called.
    let title: String?
    var ports: [PortLocation]
}

extension PaneDirectory {
    /// Every port the panes' programs are listening on: a window at a time, in the order the windows
    /// were first seen, each window's lowest port first. Every pane looks afresh first, unless told
    /// what's already known will do.
    func listening(refreshing: Bool = true) -> [ListeningWindow] {
        var windows: [ListeningWindow] = []
        for pane in panes {
            if refreshing { pane.refreshListeningPorts() }
            guard !pane.session.listeningPorts.isEmpty else { continue }
            let place = pane.host?.place(of: pane) ?? pane.session.title
            let found = pane.session.listeningPorts.map { PortLocation(port: $0, pane: pane, place: place) }
            if let index = windows.firstIndex(where: { $0.host === pane.host }) {
                windows[index].ports += found
            } else {
                windows.append(ListeningWindow(host: pane.host, title: pane.host?.windowTitle, ports: found))
            }
        }
        for index in windows.indices { windows[index].ports.sort { $0.port.port < $1.port.port } }
        return windows
    }
}

/// Window › Listening Ports: every port the programs in any pane are listening on, filled in as the
/// menu opens. Choosing one goes to its pane; with ⌥, it opens in the browser instead.
@MainActor
final class ListeningPortsMenu: NSObject, NSMenuDelegate {
    static let title = "Listening Ports"

    private let directory: PaneDirectory

    init(directory: PaneDirectory) {
        self.directory = directory
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        items().forEach(menu.addItem)
    }

    /// None of its items has a key: without this, every key pressed with ⌘ would fill the menu in,
    /// asking the kernel about every pane, to look for one.
    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                              action: UnsafeMutablePointer<Selector?>) -> Bool {
        false
    }

    /// The ports, under their window's name when they're in more than one; or a line saying there are none.
    func items() -> [NSMenuItem] {
        let windows = directory.listening()
        guard !windows.isEmpty else {
            return [NSMenuItem(title: "No Listening Ports", action: nil, keyEquivalent: "")]
        }
        var items: [NSMenuItem] = []
        for window in windows {
            if windows.count > 1 { items.append(.sectionHeader(title: window.title ?? "Window")) }
            for location in window.ports {
                let go = ClosureMenuItem(location.title, image: "network") { location.goToPane() }
                go.toolTip = "Go to the pane. Hold ⌥ to open \(location.port.url.absoluteString) in the browser."
                let open = ClosureMenuItem("Open \(location.port.url.absoluteString)", modifiers: .option, image: "safari") {
                    location.openInBrowser()
                }
                open.isAlternate = true
                items += [go, open]
            }
        }
        return items
    }
}
