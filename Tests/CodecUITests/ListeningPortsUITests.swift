import Testing
import Foundation
import AppKit
import SwiftUI
import CodecCore
@testable import CodecUI

/// The ports a pane's programs listen on, with real shells and `nc` listening for real.
@Suite("Listening ports", .serialized, .timeLimit(.minutes(2)),
       .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/nc")))
@MainActor
struct ListeningPortsUITests {
    @Test func followsWhatAPanesProgramsListenOn() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let pane = env.makePane(host: FakeHost())
        defer { pane.shutDown() }
        let window = makeTestWindow()
        window.contentView = pane.view
        pane.view.layoutSubtreeIfNeeded()
        var opened: [URL] = []
        pane.openURL = { opened.append($0) }
        #expect(await waitUntil { pane.terminal.process.running })
        #expect(pane.session.listeningPorts.isEmpty)

        // In the background, so it isn't the command in front; the pane finds it by itself.
        let port = try freePort()
        pane.terminal.send(txt: "nc -l 127.0.0.1 \(port) </dev/null &\n")
        #expect(await waitUntil { pane.session.listeningPorts.map(\.port) == [port] })
        let listening = try #require(pane.session.listeningPorts.first)
        #expect(listening.program == "nc" && !listening.foreground)
        pane.open(listening)
        #expect(opened.map(\.absoluteString) == ["http://localhost:\(port)"])

        // The address it's served at, once something prints it.
        pane.terminal.send(txt: "echo Local: https://localhost:\(port)/app\n")
        #expect(await waitUntil { pane.session.listeningPorts.first?.address == "https://localhost:\(port)/app" })
        pane.open(try #require(pane.session.listeningPorts.first))
        #expect(opened.last?.absoluteString == "https://localhost:\(port)/app")

        // Closing would end it, and says what it's listening on.
        #expect([pane].running.list == "“nc” (listening on :\(port))")
        #expect([pane].running.count == 1)
        #expect(env.environment.panes.holder(of: port)?.pane === pane)

        pane.terminal.send(txt: "kill %1\n")
        #expect(await waitUntil { pane.session.listeningPorts.isEmpty })
        #expect(env.environment.panes.holder(of: port) == nil)
    }

    @Test func aPaneThatClosedHoldsNothing() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let pane = env.makePane(host: FakeHost())
        #expect(await waitUntil { pane.terminal.process.running })
        #expect(env.environment.panes.panes.contains { $0 === pane })
        let port = try freePort()
        pane.terminal.send(txt: "nc -l 127.0.0.1 \(port) </dev/null &\n")
        #expect(await waitUntil { pane.refreshListeningPorts(); return !pane.session.listeningPorts.isEmpty })
        pane.shutDown()
        #expect(pane.session.listeningPorts.isEmpty)
        #expect(env.environment.panes.panes.isEmpty)
    }

    @Test func theStatusBarNamesWhatAPortOpens() {
        let plain = ListeningPort(port: 3000, program: "node")
        let announced = ListeningPort(port: 5173, program: "vite", address: "https://localhost:5173/app/")
        #expect(PortsStatus.help(for: plain) == "Open http://localhost:3000: “node” is listening on :3000")
        #expect(PortsStatus.menuTitle(for: plain) == "localhost:3000 — node")
        #expect(PortsStatus.menuTitle(for: announced) == "https://localhost:5173/app/ — vite")
        // One port, several or none: the chip lays out either way.
        _ = NSApplication.shared
        let widths = [[], [plain], [plain, announced]].map { ports in
            NSHostingView(rootView: PortsStatus(ports: ports, open: { _ in })).fittingSize.width
        }
        #expect(widths[0] == 0 && widths[1] > 0 && widths[2] > widths[1])
    }

    @Test func theWindowMenuListsEveryPaneThatsListening() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let menu = ListeningPortsMenu(directory: env.environment.panes)
        #expect(menu.items().map(\.title) == ["No Listening Ports"])
        #expect(menu.items().first?.action == nil)

        // Two windows, a pane listening in each.
        let front = FakeHost(), back = FakeHost()
        front.windowTitle = "web"
        back.windowTitle = "api"
        back.place = "Tab 2 › left pane"
        let panes = [env.makePane(host: front), env.makePane(host: back)]
        defer { panes.forEach { $0.shutDown() } }
        var opened: [URL] = []
        panes[1].openURL = { opened.append($0) }
        let ports = [try freePort(), try freePort()]
        for (pane, port) in zip(panes, ports) {
            #expect(await waitUntil { pane.terminal.process.running })
            pane.terminal.send(txt: "nc -l 127.0.0.1 \(port) </dev/null &\n")
        }
        #expect(await waitUntil { menu.items().count == 6 })

        // Each window's ports under its name; holding ⌥ swaps going to the pane for opening the port.
        let items = menu.items()
        #expect(items.map(\.title) == [
            "web", ":\(ports[0])  nc — Tab 1", "Open http://localhost:\(ports[0])",
            "api", ":\(ports[1])  nc — Tab 2 › left pane", "Open http://localhost:\(ports[1])",
        ])
        #expect(items.map(\.isAlternate) == [false, false, true, false, false, true])
        #expect(items[1].image != nil && items[1].toolTip?.contains("http://localhost:\(ports[0])") == true)
        #expect(items[5].keyEquivalentModifierMask == .option && items[4].keyEquivalent == items[5].keyEquivalent)

        // As the menu opens, it's filled in; choosing a port goes to its pane.
        let filled = NSMenu()
        menu.menuNeedsUpdate(filled)
        #expect(filled.items.map(\.title) == items.map(\.title))
        filled.performActionForItem(at: 4)
        #expect(back.revealed.count == 1 && back.revealed.first === panes[1] && front.revealed.isEmpty)
        filled.performActionForItem(at: 5)
        #expect(opened.map(\.absoluteString) == ["http://localhost:\(ports[1])"])

        // One window left listening: no need to say which.
        panes[0].terminal.send(txt: "kill %1\n")
        #expect(await waitUntil { menu.items().count == 2 })
        #expect(menu.items().first?.title == ":\(ports[1])  nc — Tab 2 › left pane")
    }

    @Test func thePortsTabListsEveryWindowsPortsAndNamesProcesses() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let here = FakeHost(), there = FakeHost()
        there.windowTitle = "api"
        there.place = "Tab 2 › left pane"
        let model = PortsModel(directory: env.environment.panes)
        model.host = here
        let panes = [env.makePane(host: there), env.makePane(host: here)]
        defer { panes.forEach { $0.shutDown() } }
        let ports = [try freePort(), try freePort()]
        for (pane, port) in zip(panes, ports) {
            #expect(await waitUntil { pane.terminal.process.running })
            pane.terminal.send(txt: "nc -l 127.0.0.1 \(port) </dev/null &\n")
        }
        // Not showing: it doesn't keep up.
        #expect(await waitUntil { panes.allSatisfy { !$0.session.listeningPorts.isEmpty } })
        #expect(model.sections.isEmpty)

        // Showing: this window's ports first, each window under its name.
        model.isActive = true
        #expect(model.sections.map(\.title) == ["This Window", "api"])
        #expect(model.rows.map(\.port.port) == [ports[1], ports[0]])
        #expect(model.rows.map(\.detail) == ["Tab 1", "Tab 2 › left pane"])
        #expect(PortsList.count(model.rows.count) == "2 ports" && PortsList.count(1) == "1 port" && PortsList.count(0).isEmpty)

        // A name for the process in the other window: it shows wherever the port does.
        let row = try #require(model.rows.last)
        model.naming = row.id
        model.finishNaming(row, as: "Billing API")
        #expect(model.naming == nil)
        #expect(model.rows.last?.port.displayName == "Billing API")
        #expect(model.rows.last?.detail == "nc · Tab 2 › left pane")
        #expect(panes[0].session.listeningPorts.first?.name == "Billing API")
        #expect(ListeningPortsMenu(directory: env.environment.panes).items().map(\.title).contains(":\(ports[0])  Billing API — Tab 2 › left pane"))
        #expect(PortsStatus.help(for: try #require(panes[0].session.listeningPorts.first)).contains("“Billing API” is listening"))
        // It keeps it while it runs.
        panes[0].refreshListeningPorts()
        #expect(panes[0].session.listeningPorts.first?.name == "Billing API")
        // A command that finds the port taken is told who by that name.
        var entry = TimelineEntry(id: 1, command: "nc -l \(ports[0])", directory: "/tmp", started: Date(), block: nil)
        entry.exitCode = 1
        entry.portConflict = PortConflict(port: ports[0], program: "nc", pane: panes[0].session.id.uuidString)
        #expect(panes[1].portConflictStatus(of: entry)?.text == "Port \(ports[0]) is in use by “Billing API” in another window, Tab 2 › left pane")

        // Cancelling leaves the name; a blank one takes it away.
        let named = try #require(model.rows.last)
        model.finishNaming(named, as: nil)
        #expect(model.rows.last?.port.name == "Billing API")
        model.finishNaming(named, as: " ")
        #expect(model.rows.last?.port.name == nil && model.rows.last?.detail == "Tab 2 › left pane")

        // Going to a port's pane, opening it, and following along as servers stop.
        var opened: [URL] = []
        panes[0].openURL = { opened.append($0) }
        model.goToPane(try #require(model.rows.last))
        #expect(there.revealed.count == 1 && there.revealed.first === panes[0])
        model.openInBrowser(try #require(model.rows.last))
        #expect(opened.map(\.absoluteString) == ["http://localhost:\(ports[0])"])
        panes[1].terminal.send(txt: "kill %1\n")
        #expect(await waitUntil { model.rows.count == 1 })
        // Only another window's left: still under its name.
        #expect(model.sections.map(\.title) == ["api"])
        panes[0].shutDown()
        #expect(model.sections.isEmpty)
    }

    @Test func theRightSidebarHasCommandsAndPorts() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let controller = TerminalWindowController(directory: env.directory.path, environment: env.environment)
        controller.window?.setContentSize(NSSize(width: 1100, height: 600))
        defer {
            controller.model.tabs.flatMap(\.panes).forEach { $0.shutDown() }
            controller.window?.close()
        }
        let pane = try #require(controller.model.selected?.focused)
        #expect(await waitUntil { pane.terminal.process.running })
        #expect(!controller.model.timelineVisible && controller.model.inspectorTab == .commands)
        #expect(controller.paletteCommands().contains { $0.id == "ports" && $0.title == "Show Listening Ports" && $0.shortcut == "⇧⌘O" })

        // ⇧⌘O shows the Ports tab in place of Commands, and keeps up with the panes while it shows.
        controller.togglePorts(nil)
        controller.window?.layoutIfNeeded()
        #expect(controller.model.timelineVisible && controller.model.inspectorTab == .ports)
        #expect(!controller.portsSidebar.isHidden && controller.timelineSidebar.isHidden)
        #expect(controller.portsSidebar.frame.width == CommandTimelineSidebar.defaultWidth)
        #expect(controller.timelineSidebar.pane == nil)
        #expect(controller.ports.isActive && controller.ports.sections.isEmpty)
        #expect(controller.paletteCommands().contains { $0.id == "ports" && $0.title == "Hide Listening Ports" })
        #expect(controller.paletteCommands().contains { $0.id == "commands" && $0.title == "Show Commands Sidebar" })
        let port = try freePort()
        pane.terminal.send(txt: "nc -l 127.0.0.1 \(port) </dev/null &\n")
        #expect(await waitUntil { controller.ports.rows.map(\.port.port) == [port] })
        // All in this window: no need to say which.
        #expect(controller.ports.sections.map(\.title) == [nil])
        #expect(controller.ports.rows.first?.detail == "Tab 1")
        // Where its pane is follows the window's tabs and splits.
        controller.splitRight(nil)
        #expect(await waitUntil { controller.ports.rows.first?.detail == "Tab 1 › left pane" })

        // ⇧⌘L goes to Commands; the Ports tab stops following.
        controller.toggleCommandTimeline(nil)
        #expect(controller.model.timelineVisible && controller.model.inspectorTab == .commands)
        #expect(controller.portsSidebar.isHidden && !controller.timelineSidebar.isHidden && !controller.ports.isActive)
        #expect(controller.timelineSidebar.pane === controller.model.selected?.focused)
        // Again hides the sidebar; ⇧⌘O then brings it back on Ports, and again hides it.
        controller.toggleCommandTimeline(nil)
        #expect(!controller.model.timelineVisible)
        controller.togglePorts(nil)
        #expect(controller.model.timelineVisible && controller.model.inspectorTab == .ports && controller.ports.isActive)
        controller.togglePorts(nil)
        controller.window?.layoutIfNeeded()
        #expect(!controller.model.timelineVisible && !controller.ports.isActive)
        #expect(controller.portsSidebar.frame.width == 0)

        // The next window opens the sidebar on the tab this one left it on.
        controller.togglePorts(nil)
        let next = TerminalWindowController(directory: env.directory.path, environment: env.environment)
        defer {
            next.model.tabs.flatMap(\.panes).forEach { $0.shutDown() }
            next.window?.close()
        }
        #expect(next.model.timelineVisible && next.model.inspectorTab == .ports)
        // Its list has the first window's port, under that window's name.
        #expect(next.ports.rows.map(\.port.port) == [port])
        #expect(next.ports.sections.first?.title != nil && next.ports.sections.first?.title != "This Window")
    }

    @Test func aRunningCommandsRowSaysWhatItsListeningOn() {
        let cell = TimelineCell()
        let entry = TimelineEntry(id: 1, command: "npm run dev", directory: "/tmp/web", started: Date(), block: nil)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        cell.show(entry, query: "", inScrollback: true, theme: .codec, codeFont: font)
        #expect(cell.shown.detail == "Running…")
        cell.show(entry, query: "", inScrollback: true, theme: .codec, codeFont: font,
                  listening: [ListeningPort(port: 3000, program: "node"), ListeningPort(port: 9229, program: "node")])
        #expect(cell.shown.detail == "Listening on :3000 and :9229")
        #expect(!cell.offersGoToPane)
    }
}

/// A command that finds its port taken by a program in another pane, in a window with real zsh.
@Suite("Port conflicts", .serialized, .timeLimit(.minutes(2)),
       .enabled(if: ["/bin/zsh", "/usr/bin/nc", "/usr/bin/perl"].allSatisfy(FileManager.default.isExecutableFile(atPath:))))
@MainActor
struct PortConflictUITests {
    @Test func saysWhichPaneHasThePortAndGoesToIt() async throws {
        let env = try TestEnvironment(shell: "/bin/zsh", integration: true, explainer: FakeExplainer())
        defer { env.tearDown() }
        let config = env.directory.appendingPathComponent("zdotdir")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "PS1='%# '\n".write(to: config.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        setenv("ZDOTDIR", config.path, 1)
        defer { unsetenv("ZDOTDIR") }
        // macOS's nc shares its port with whoever asks, so the one refused is a program that doesn't.
        try """
            use IO::Socket::INET;
            IO::Socket::INET->new(Listen => 1, LocalAddr => "127.0.0.1", LocalPort => $ARGV[0]) or die "bind: $!\n";
            sleep 30;
            """.write(to: env.directory.appendingPathComponent("listen.pl"), atomically: true, encoding: .utf8)
        let controller = TerminalWindowController(directory: env.directory.path, environment: env.environment)
        controller.window?.setContentSize(NSSize(width: 1100, height: 600))
        defer {
            controller.model.tabs.flatMap(\.panes).forEach { $0.shutDown() }
            controller.window?.close()
        }
        let tab = try #require(controller.model.selected)
        let server = tab.focused
        #expect(await waitUntil { server.isAtCommandLine })
        #expect(controller.place(of: server) == "Tab 1")

        // A server in the first pane, in the foreground.
        let port = try freePort()
        server.terminal.send(txt: "nc -l 127.0.0.1 \(port)\r")
        #expect(await waitUntil { server.session.listeningPorts.map(\.port) == [port] })
        #expect(server.session.listeningPorts.first?.foreground == true)
        #expect(tab.toolTip.hasSuffix("\nListening on :\(port) (nc)"))
        #expect(controller.allPanes.running.list == "“nc” (listening on :\(port))")

        controller.toggleCommandTimeline(nil)
        controller.window?.layoutIfNeeded()
        let sidebar = controller.timelineSidebar!
        let runningRow = try #require(sidebar.rows.lastIndex { $0.entry?.isRunning == true })
        #expect(await waitUntil {
            (sidebar.table.view(atColumn: 0, row: runningRow, makeIfNecessary: true) as? TimelineCell)?.shown.detail == "Listening on :\(port)"
        })

        // The same in a second pane: refused, and Codec knows who has the port.
        controller.splitRight(nil)
        let client = tab.focused
        #expect(client !== server)
        #expect(controller.place(of: server) == "Tab 1 › left pane")
        #expect(await waitUntil { client.isAtCommandLine })

        // The command palette knows the way to the server, and what it serves.
        var opened: [URL] = []
        server.openURL = { opened.append($0) }
        let commands = controller.paletteCommands()
        let goTo = try #require(commands.first { $0.title == "Go to :\(port) — nc, Tab 1 › left pane" })
        goTo.action()
        #expect(tab.focused === server)
        try #require(commands.first { $0.title == "Open http://localhost:\(port) in the Browser" }).action()
        #expect(opened.map(\.absoluteString) == ["http://localhost:\(port)"])
        tab.focus(client)

        client.terminal.send(txt: "perl listen.pl \(port)\r")
        #expect(await waitUntil { client.timeline.entries.last?.portConflict != nil })
        let failed = try #require(client.timeline.entries.last)
        #expect(failed.portConflict == PortConflict(port: port, program: "nc", pane: server.session.id.uuidString))
        let status = try #require(client.portConflictStatus(of: failed))
        #expect(status.text == "Port \(port) is in use by “nc” in Tab 1 › left pane")
        #expect(status.holder === server)

        // Its row says so, with the way there.
        #expect(sidebar.pane === client)
        let row = try #require(sidebar.rows.firstIndex { $0.entry?.id == failed.id })
        #expect(await waitUntil { sidebar.tableView(sidebar.table, heightOfRow: row) == TimelineCell.heightSayingWhyAndWhere })
        let cell = try #require(sidebar.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? TimelineCell)
        #expect(cell.shown.detail == status.text)
        #expect(cell.offersGoToPane)
        #expect(sidebar.contextMenuItems(for: failed, row: row).map(\.title).contains("Go to Pane Listening on :\(port)"))

        // So does its output, and what's sent to explain it.
        sidebar.showOutput(of: failed, row: row)
        #expect(sidebar.outputViewer?.portConflict?.text == status.text)
        #expect(sidebar.outputViewer?.explanation.report?.known.hasPrefix("Port \(port) is in use by “nc”") == true)

        cell.pressGoToPane()
        #expect(tab.focused === server)
        #expect(!sidebar.isShowingOutput)

        // Once the server is stopped, there's nowhere to go.
        server.terminal.send(txt: "\u{03}")
        #expect(await waitUntil { server.session.listeningPorts.isEmpty })
        let after = try #require(client.portConflictStatus(of: failed))
        #expect(after.text == "Port \(port) was in use by “nc”" && after.holder == nil)
        tab.focus(client)
        #expect(await waitUntil { sidebar.pane === client })
        let rowAfter = try #require(sidebar.rows.firstIndex { $0.entry?.id == failed.id })
        #expect(sidebar.tableView(sidebar.table, heightOfRow: rowAfter) == TimelineCell.heightSayingWhy)
        let cellAfter = try #require(sidebar.table.view(atColumn: 0, row: rowAfter, makeIfNecessary: true) as? TimelineCell)
        #expect(cellAfter.shown.detail == after.text && !cellAfter.offersGoToPane)
        #expect(!sidebar.contextMenuItems(for: failed, row: rowAfter).map(\.title).contains { $0.hasPrefix("Go to Pane") })
    }

    @Test func aPortHeldInTheSamePaneOrAnotherWindowSaysSo() async throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let host = FakeHost(), other = FakeHost()
        other.place = "Tab 3 › top pane"
        let pane = env.makePane(host: host), elsewhere = env.makePane(host: other)
        defer { [pane, elsewhere].forEach { $0.shutDown() } }
        var entry = TimelineEntry(id: 1, command: "npm run dev", directory: "/tmp", started: Date(), block: nil)
        entry.exitCode = 1
        #expect(pane.portConflictStatus(of: entry) == nil)

        entry.portConflict = PortConflict(port: 3000, program: "node", pane: pane.session.id.uuidString)
        // Nothing listens: it has let go of the port since.
        #expect(pane.portConflictStatus(of: entry)?.text == "Port 3000 was in use by “node”")
        pane.session.listeningPorts = [ListeningPort(port: 3000, program: "node")]
        let here = try #require(pane.portConflictStatus(of: entry))
        #expect(here.text == "Port 3000 is in use by “node” in this pane" && here.holder == nil)

        entry.portConflict = PortConflict(port: 3000, program: "node", pane: elsewhere.session.id.uuidString)
        elsewhere.session.listeningPorts = [ListeningPort(port: 3000, program: "node")]
        let there = try #require(pane.portConflictStatus(of: entry))
        #expect(there.text == "Port 3000 is in use by “node” in another window, Tab 3 › top pane")
        #expect(there.holder === elsewhere)

        // A pane that's gone, as after quitting and coming back.
        entry.portConflict = PortConflict(port: 3000, program: "node", pane: UUID().uuidString)
        #expect(pane.portConflictStatus(of: entry)?.holder == nil)
    }
}
