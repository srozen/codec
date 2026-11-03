import Testing
import AppKit
import CodecCore
@testable import CodecUI

@Suite("TerminalTab", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct TerminalTabTests {
    @Test func splitsFocusTheNewPane() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let first = env.makePane(), second = env.makePane(), third = env.makePane()
        defer { [first, second, third].forEach { $0.shutDown() } }
        let tab = TerminalTab(pane: first)
        tab.split(first, with: second, axis: .horizontal)
        #expect(tab.focused === second)
        tab.split(second, with: third, axis: .vertical)
        #expect(tab.panes.map(\.session.id) == [first, second, third].map(\.session.id))
        #expect(tab.focused === third)
    }

    @Test func splitsLeftAndUpPutTheNewPaneFirst() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let first = env.makePane(), second = env.makePane(), third = env.makePane()
        defer { [first, second, third].forEach { $0.shutDown() } }
        let tab = TerminalTab(pane: first)
        tab.split(first, with: second, axis: .horizontal, before: true)
        #expect(tab.focused === second)
        tab.split(first, with: third, axis: .vertical, before: true)
        #expect(tab.focused === third)
        #expect(tab.panes.map(\.session.id) == [second, third, first].map(\.session.id))
    }

    @Test func removingFocusesTheNeighbor() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let first = env.makePane(), second = env.makePane(), third = env.makePane()
        defer { [first, second, third].forEach { $0.shutDown() } }
        let tab = TerminalTab(pane: first)
        tab.split(first, with: second, axis: .horizontal)
        tab.split(second, with: third, axis: .horizontal)
        tab.focus(second)
        #expect(!tab.remove(second))
        #expect(tab.focused === third)
        #expect(!tab.remove(third))
        #expect(tab.focused === first)
        #expect(tab.remove(first))
    }

    @Test func cyclesThroughPanes() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let first = env.makePane(), second = env.makePane()
        defer { [first, second].forEach { $0.shutDown() } }
        let tab = TerminalTab(pane: first)
        tab.split(first, with: second, axis: .vertical)
        tab.cyclePane(forward: true)
        #expect(tab.focused === first)
        tab.cyclePane(forward: false)
        #expect(tab.focused === second)
    }

    @Test func ignoresPanesItDoesntHold() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let first = env.makePane(), stranger = env.makePane(), new = env.makePane()
        defer { [first, stranger, new].forEach { $0.shutDown() } }
        let tab = TerminalTab(pane: first)
        tab.focus(stranger)
        tab.split(stranger, with: new, axis: .horizontal)
        #expect(tab.focused === first)
        #expect(tab.panes.count == 1)
    }

    @Test func renamingOverridesTheAutomaticTitle() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let pane = env.makePane()
        defer { pane.shutDown() }
        let tab = TerminalTab(pane: pane)
        pane.session.processName = "sh"
        #expect(tab.title == env.directory.lastPathComponent)
        tab.rename(to: "  Server logs  ")
        #expect(tab.customTitle == "Server logs")
        #expect(tab.title == "Server logs")
        pane.session.processName = "vim"
        #expect(tab.title == "Server logs")
        #expect(tab.automaticTitle == "vim")
    }

    @Test(arguments: [String?.none, "", "   \n"])
    func blankNamesGoBackToAutomatic(name: String?) throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let pane = env.makePane()
        defer { pane.shutDown() }
        let tab = TerminalTab(pane: pane)
        tab.rename(to: "API")
        tab.rename(to: name)
        #expect(tab.customTitle == nil)
        #expect(tab.title == tab.automaticTitle)
    }

    @Test func buildsNestedSplitViews() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let first = env.makePane(), second = env.makePane(), third = env.makePane()
        defer { [first, second, third].forEach { $0.shutDown() } }
        let tab = TerminalTab(pane: first)
        tab.split(first, with: second, axis: .horizontal)
        tab.split(second, with: third, axis: .vertical)
        let root = try #require(tab.makeView(divider: .red) as? PaneSplitView)
        #expect(root.isVertical)
        #expect(root.arrangedSubviews.first === first.view)
        let nested = try #require(root.arrangedSubviews.last as? PaneSplitView)
        #expect(!nested.isVertical)
        #expect(nested.arrangedSubviews.map { $0 as? PaneView } == [second.view, third.view])
    }
}

@Suite("Window", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct WindowTests {
    private func makeWindow(_ env: TestEnvironment) -> TerminalWindowController {
        let controller = TerminalWindowController(directory: env.directory.path, environment: env.environment)
        controller.window?.setContentSize(NSSize(width: 900, height: 600))
        controller.window?.layoutIfNeeded()
        return controller
    }

    private func close(_ controller: TerminalWindowController) {
        controller.window?.close()
    }

    /// Regression: only the command line took focus; clicks elsewhere landed on the inactive-pane
    /// dimmer, or reached a terminal that didn't take the keyboard.
    @Test func clickingAnywhereInAPaneFocusesIt() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let controller = makeWindow(env)
        defer { close(controller) }
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        controller.splitRight(nil)
        window.layoutIfNeeded()
        let tab = try #require(controller.model.selected)
        let (left, right) = (tab.panes[0], tab.panes[1])

        func click(_ pane: Pane, at local: NSPoint) throws {
            let point = pane.view.convert(local, to: nil)
            let hit = try #require(content.hitTest(content.convert(point, from: nil)))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                if type == .leftMouseDown { hit.mouseDown(with: event) } else { hit.mouseUp(with: event) }
            }
        }

        #expect(tab.focused === right)
        // The middle of the output, well away from the command line, in a dimmed pane.
        try click(left, at: NSPoint(x: left.view.bounds.midX, y: left.view.bounds.midY))
        #expect(tab.focused === left)
        #expect(window.firstResponder === left.terminal)
        // The padding around the terminal.
        try click(right, at: NSPoint(x: 4, y: right.view.bounds.midY))
        #expect(tab.focused === right)
        #expect(window.firstResponder === right.terminal)
        // The dimmer never takes the click from the terminal.
        let middle = left.view.convert(NSPoint(x: left.view.bounds.midX, y: left.view.bounds.midY), to: nil)
        #expect(content.hitTest(content.convert(middle, from: nil))?.isDescendant(of: left.terminal) == true)
    }

    @Test func middleClickClosesATab() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let controller = makeWindow(env)
        defer { close(controller) }
        controller.newTab(nil)
        controller.window?.layoutIfNeeded()
        controller.tabBar.layoutSubtreeIfNeeded()
        #expect(controller.model.tabs.count == 2)

        func catchers(in view: NSView) -> [MiddleClickCatcher.CatcherView] {
            view.subviews.flatMap { ($0 as? MiddleClickCatcher.CatcherView).map { [$0] } ?? catchers(in: $0) }
        }
        let found = catchers(in: controller.tabBar)
        #expect(found.count == 2)
        let catcher = try #require(found.first)
        let window = try #require(controller.window)
        // At the screen's origin, window coordinates are screen coordinates, which events made from
        // Core Graphics (the only way to set the middle button) carry.
        window.setFrameOrigin(.zero)
        let center = catcher.convert(NSPoint(x: catcher.bounds.midX, y: catcher.bounds.midY), to: nil)
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        func event(_ type: CGEventType) -> NSEvent {
            let cg = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: center.x, y: screenHeight - center.y),
                             mouseButton: .center)!
            return NSEvent(cgEvent: cg)!
        }
        let down = event(.otherMouseDown), up = event(.otherMouseUp)
        try #require(up.buttonNumber == 2)
        try #require(catcher.bounds.contains(catcher.convert(up.locationInWindow, from: nil)))
        catcher.otherMouseDown(with: down)
        catcher.otherMouseUp(with: up)
        #expect(controller.model.tabs.count == 1)
    }

    @Test func movesTabs() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let controller = makeWindow(env)
        defer { close(controller) }
        controller.newTab(nil)
        controller.newTab(nil)
        let tabs = controller.model.tabs
        zip(tabs, ["a", "b", "c"]).forEach { $0.rename(to: $1) }
        controller.move(tabs[0], to: 2)
        #expect(controller.model.tabs.map(\.id) == [tabs[1], tabs[2], tabs[0]].map(\.id))
        controller.move(tabs[0], to: 0)
        #expect(controller.model.tabs.map(\.id) == tabs.map(\.id))
        controller.move(tabs[1], to: 99)
        #expect(controller.model.tabs.last === tabs[1])
        // ⌘1 follows the order on screen; the saved window keeps it too.
        let first = NSMenuItem()
        first.tag = 1
        controller.selectTabByNumber(first)
        #expect(controller.model.selected === tabs[0])
        #expect(controller.savedState.tabs.map(\.title) == ["a", "c", "b"])
    }

    @Test func aDraggedTabLandsAfterTheTabsWhoseMiddleItPassed() {
        let frames = [CGRect(x: 0, y: 0, width: 100, height: 28), CGRect(x: 104, y: 0, width: 100, height: 28),
                      CGRect(x: 208, y: 0, width: 100, height: 28)]
        #expect(TabBar.landingIndex(of: 0, drawnAt: 150, among: frames) == 0)
        #expect(TabBar.landingIndex(of: 0, drawnAt: 160, among: frames) == 1)
        #expect(TabBar.landingIndex(of: 0, drawnAt: 400, among: frames) == 2)
        #expect(TabBar.landingIndex(of: 2, drawnAt: 160, among: frames) == 2)
        #expect(TabBar.landingIndex(of: 2, drawnAt: 150, among: frames) == 1)
        #expect(TabBar.landingIndex(of: 2, drawnAt: -20, among: frames) == 0)
    }

    @Test func theOtherTabsSlideAsideToShowWhereItWillLand() {
        // The first of four dragged to the third place: the second and third slide left.
        #expect((0..<4).map { TabBar.slide($0, from: 0, to: 2, by: 104) } == [0, -104, -104, 0])
        // The last dragged to the second place: the second and third slide right.
        #expect((0..<4).map { TabBar.slide($0, from: 3, to: 1, by: 104) } == [0, 104, 104, 0])
        #expect((0..<4).map { TabBar.slide($0, from: 2, to: 2, by: 104) } == [0, 0, 0, 0])
    }

    @Test func dragsOnTabsDontMoveTheWindow() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let controller = makeWindow(env)
        defer { close(controller) }
        #expect(!controller.tabBar.mouseDownCanMoveWindow)
    }

    @Test func opensWithOneTabInTheRequestedDirectory() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let window = makeWindow(env)
        defer { close(window) }
        #expect(window.model.tabs.count == 1)
        #expect(window.model.selected?.focused.session.directory == env.directory.path)
        #expect(window.window?.title == env.directory.lastPathComponent)
    }

    /// Regression: the tab bar's content was pushed down into the terminal by the title bar's safe area.
    @Test func chromeIgnoresTheTitleBarSafeArea() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let window = makeWindow(env)
        defer { close(window) }
        #expect(window.tabBar.safeAreaRegions.isEmpty)
        #expect(window.statusBar.safeAreaRegions.isEmpty)
    }

    @Test func laysOutTabBarTerminalAndStatusBarWithoutOverlap() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let controller = makeWindow(env)
        defer { close(controller) }
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        let tabBar = controller.tabBar.frame, panes = controller.paneContainer.frame, status = controller.statusBar.frame
        #expect(tabBar.maxY == content.bounds.maxY)
        #expect(tabBar.height == TabBar.height)
        #expect(panes.maxY == tabBar.minY)
        #expect(panes.minY == status.maxY)
        #expect(status.minY == 0)
        // The title bar the system draws is exactly the tab bar's height, so the traffic lights sit on it.
        #expect(window.frame.height - window.contentLayoutRect.maxY == TabBar.height)
    }

    @Test func newTabsOpenAfterTheCurrentOneInItsDirectory() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let window = makeWindow(env)
        defer { close(window) }
        let sub = env.directory.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        window.model.selected?.focused.session.directory = sub.path
        window.newTab(nil)
        #expect(window.model.tabs.count == 2)
        #expect(window.model.selectedID == window.model.tabs[1].id)
        #expect(window.model.selected?.focused.session.directory == sub.path)
    }

    @Test func splitsAndClosesPanes() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let window = makeWindow(env)
        defer { close(window) }
        let tab = try #require(window.model.selected)
        let first = tab.focused
        window.splitRight(nil)
        window.splitDown(nil)
        #expect(tab.panes.count == 3)
        #expect(window.paneContainer.subviews.first is PaneSplitView)
        let last = tab.focused
        window.paneDidFinish(last)
        #expect(tab.panes.count == 2)
        #expect(last.isShutDown)
        window.paneDidFinish(tab.focused)
        #expect(tab.panes.count == 1)
        #expect(tab.focused === first)
        #expect(window.paneContainer.subviews.first === first.view)
    }

    @Test func dimsInactivePanes() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let window = makeWindow(env)
        defer { close(window) }
        let tab = try #require(window.model.selected)
        let first = tab.focused
        window.splitRight(nil)
        #expect(first.view.isDimmed)
        #expect(!tab.focused.view.isDimmed)
        env.preferences.dimInactivePanes = false
        #expect(!first.view.isDimmed)
    }

    @Test func closingTheLastPaneClosesTheTabThenTheWindow() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let window = makeWindow(env)
        var closed = false
        window.onClose = { _ in closed = true }
        window.newTab(nil)
        let second = try #require(window.model.selected)
        window.paneDidFinish(second.focused)
        #expect(window.model.tabs.count == 1)
        #expect(!closed)
        let first = try #require(window.model.selected)
        window.paneDidFinish(first.focused)
        #expect(window.model.tabs.isEmpty)
        #expect(closed)
    }

    @Test func switchesTabs() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let window = makeWindow(env)
        defer { close(window) }
        window.newTab(nil)
        window.newTab(nil)
        let ids = window.model.tabs.map(\.id)
        window.nextTab(nil)
        #expect(window.model.selectedID == ids[0])
        window.previousTab(nil)
        #expect(window.model.selectedID == ids[2])
        let item = NSMenuItem()
        item.tag = 2
        window.selectTabByNumber(item)
        #expect(window.model.selectedID == ids[1])
        item.tag = 9
        window.selectTabByNumber(item)
        #expect(window.model.selectedID == ids[2])
    }

    @Test func paletteListsCommandsAndRunsThem() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let window = makeWindow(env)
        defer { close(window) }
        let commands = window.paletteCommands()
        let ids = Set(commands.map(\.id))
        for id in ["new-tab", "split-right", "split-down", "close-pane", "previous-command", "settings", "theme-amber"] {
            #expect(ids.contains(id), "missing \(id)")
        }
        #expect(ids.count == commands.count, "palette IDs must be unique")

        commands.first { $0.id == "theme-amber" }?.action()
        #expect(env.preferences.themeID == "amber")
        commands.first { $0.id == "split-right" }?.action()
        #expect(window.model.selected?.panes.count == 2)
        commands.first { $0.id == "new-window" }?.action()
        commands.first { $0.id == "settings" }?.action()
        #expect(env.coordinator.newWindows == 1)
        #expect(env.coordinator.settingsShown == 1)
    }

    @Test func paletteCapturesTheMouseOnlyWhileOpen() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let window = makeWindow(env)
        defer { close(window) }
        window.showCommandPalette(nil)
        #expect(window.model.paletteOpen)
        window.showCommandPalette(nil)
        #expect(!window.model.paletteOpen)
    }

    @Test func renamesTheSelectedTabThroughTheEditor() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let window = makeWindow(env)
        defer { close(window) }
        let tab = try #require(window.model.selected)
        window.renameTab(nil)
        #expect(window.model.renamingTabID == tab.id)
        window.finishRenaming(tab, to: "Deploy")
        #expect(window.model.renamingTabID == nil)
        #expect(tab.title == "Deploy")
        #expect(window.window?.title == "Deploy")
    }

    @Test func cancellingKeepsTheName() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let window = makeWindow(env)
        defer { close(window) }
        let tab = try #require(window.model.selected)
        tab.rename(to: "Build")
        window.beginRenaming(tab)
        window.finishRenaming(tab, to: nil)
        #expect(window.model.renamingTabID == nil)
        #expect(tab.title == "Build")
    }

    @Test func renamingAnotherTabSelectsIt() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let window = makeWindow(env)
        defer { close(window) }
        let first = try #require(window.model.selected)
        window.newTab(nil)
        window.beginRenaming(first)
        #expect(window.model.selectedID == first.id)
        #expect(window.model.renamingTabID == first.id)
    }

    @Test func closingTheTabBeingRenamedEndsTheEdit() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let window = makeWindow(env)
        defer { close(window) }
        window.newTab(nil)
        let tab = try #require(window.model.selected)
        window.beginRenaming(tab)
        window.paneDidFinish(tab.focused)
        #expect(window.model.renamingTabID == nil)
        #expect(window.model.tabs.count == 1)
    }

    @Test func paletteCanRenameAndResetTabs() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let window = makeWindow(env)
        defer { close(window) }
        let tab = try #require(window.model.selected)
        #expect(!window.paletteCommands().contains { $0.id == "reset-tab-name" })
        window.paletteCommands().first { $0.id == "rename-tab" }?.action()
        #expect(window.model.renamingTabID == tab.id)
        window.finishRenaming(tab, to: "Tests")
        #expect(window.paletteCommands().contains { $0.title == "Go to Tab 1: Tests" })
        window.paletteCommands().first { $0.id == "reset-tab-name" }?.action()
        #expect(tab.customTitle == nil)
        #expect(window.window?.title == tab.automaticTitle)
    }

    @Test func revealsAPaneBySessionID() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let window = makeWindow(env)
        defer { close(window) }
        let firstTab = try #require(window.model.selected)
        window.newTab(nil)
        #expect(window.reveal(sessionID: firstTab.focused.session.id.uuidString))
        #expect(window.model.selectedID == firstTab.id)
        #expect(!window.reveal(sessionID: UUID().uuidString))
    }
}
