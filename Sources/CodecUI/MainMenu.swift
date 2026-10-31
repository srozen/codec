import AppKit

/// The menu bar, built in code since there is no nib.
@MainActor
enum MainMenu {
    private typealias W = TerminalWindowController

    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(shellMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: "Help")
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        return item
    }

    private static func arrow(_ key: Int) -> String {
        String(Character(UnicodeScalar(key)!))
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Codec")
        menu.addItem(item("About Codec", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ","))
        menu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(item("Hide Codec", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit Codec", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func shellMenu() -> NSMenu {
        let menu = NSMenu(title: "Shell")
        menu.addItem(item("New Window", #selector(AppDelegate.newWindow(_:)), "n"))
        menu.addItem(item("New Tab", #selector(AppDelegate.newTab(_:)), "t"))
        menu.addItem(.separator())
        menu.addItem(item("Split Right", #selector(W.splitRight(_:)), "d"))
        menu.addItem(item("Split Down", #selector(W.splitDown(_:)), "d", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Close Pane", #selector(W.closePane(_:)), "w"))
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Restart Shell", #selector(W.restartShell(_:))))
        menu.addItem(item("Clear Buffer", #selector(W.clearBuffer(_:)), "k"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        let find = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")
        let findAction = #selector(NSTextView.performFindPanelAction(_:))
        findMenu.addItem(item("Find…", findAction, "f", tag: Int(NSFindPanelAction.showFindPanel.rawValue)))
        findMenu.addItem(item("Find Next", findAction, "g", tag: Int(NSFindPanelAction.next.rawValue)))
        findMenu.addItem(item("Find Previous", findAction, "g", [.command, .shift], tag: Int(NSFindPanelAction.previous.rawValue)))
        findMenu.addItem(item("Use Selection for Find", findAction, "e", tag: Int(NSFindPanelAction.setFindString.rawValue)))
        find.submenu = findMenu
        menu.addItem(find)
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Command Palette…", #selector(W.showCommandPalette(_:)), "p", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Jump to Previous Command", #selector(W.previousCommand(_:)), arrow(NSUpArrowFunctionKey)))
        menu.addItem(item("Jump to Next Command", #selector(W.nextCommand(_:)), arrow(NSDownArrowFunctionKey)))
        menu.addItem(.separator())
        menu.addItem(item("Bigger", #selector(W.biggerFont(_:)), "+"))
        let alternate = item("Bigger", #selector(W.biggerFont(_:)), "=")
        alternate.isHidden = true
        alternate.allowsKeyEquivalentWhenHidden = true
        menu.addItem(alternate)
        menu.addItem(item("Smaller", #selector(W.smallerFont(_:)), "-"))
        menu.addItem(item("Actual Size", #selector(W.resetFontSize(_:)), "0"))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Next Tab", #selector(W.nextTab(_:)), "]", [.command, .shift]))
        menu.addItem(item("Previous Tab", #selector(W.previousTab(_:)), "[", [.command, .shift]))
        let controlTab = item("Next Tab", #selector(W.nextTab(_:)), "\t", .control)
        controlTab.isHidden = true
        controlTab.allowsKeyEquivalentWhenHidden = true
        menu.addItem(controlTab)
        let controlShiftTab = item("Previous Tab", #selector(W.previousTab(_:)), "\t", [.control, .shift])
        controlShiftTab.isHidden = true
        controlShiftTab.allowsKeyEquivalentWhenHidden = true
        menu.addItem(controlShiftTab)
        menu.addItem(item("Rename Tab…", #selector(W.renameTab(_:)), "r", [.command, .shift]))
        let tabs = NSMenuItem(title: "Go to Tab", action: nil, keyEquivalent: "")
        let tabsMenu = NSMenu(title: "Go to Tab")
        for n in 1...9 {
            tabsMenu.addItem(item(n == 9 ? "Last Tab" : "Tab \(n)", #selector(W.selectTabByNumber(_:)), "\(n)", tag: n))
        }
        tabs.submenu = tabsMenu
        menu.addItem(tabs)
        menu.addItem(.separator())
        menu.addItem(item("Next Pane", #selector(W.nextPane(_:)), "]"))
        menu.addItem(item("Previous Pane", #selector(W.previousPane(_:)), "["))
        let panes = NSMenuItem(title: "Focus Pane", action: nil, keyEquivalent: "")
        let panesMenu = NSMenu(title: "Focus Pane")
        panesMenu.addItem(item("Left", #selector(W.focusPaneLeft(_:)), arrow(NSLeftArrowFunctionKey), [.command, .option]))
        panesMenu.addItem(item("Right", #selector(W.focusPaneRight(_:)), arrow(NSRightArrowFunctionKey), [.command, .option]))
        panesMenu.addItem(item("Above", #selector(W.focusPaneUp(_:)), arrow(NSUpArrowFunctionKey), [.command, .option]))
        panesMenu.addItem(item("Below", #selector(W.focusPaneDown(_:)), arrow(NSDownArrowFunctionKey), [.command, .option]))
        panes.submenu = panesMenu
        menu.addItem(panes)
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
}
