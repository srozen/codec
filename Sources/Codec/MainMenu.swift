import AppKit

/// The menu bar, built in code since there is no nib.
@MainActor
enum MainMenu {
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

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Codec")
        menu.addItem(item("About Codec", #selector(AppDelegate.showAbout(_:))))
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
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(.separator())
        menu.addItem(item("Clear Buffer", #selector(ChannelWindowController.clearBuffer(_:)), "k"))
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
        menu.addItem(item("Bigger", #selector(ChannelWindowController.biggerFont(_:)), "+"))
        let alternate = item("Bigger", #selector(ChannelWindowController.biggerFont(_:)), "=")
        alternate.isAlternate = false
        alternate.isHidden = true
        alternate.allowsKeyEquivalentWhenHidden = true
        menu.addItem(alternate)
        menu.addItem(item("Smaller", #selector(ChannelWindowController.smallerFont(_:)), "-"))
        menu.addItem(item("Actual Size", #selector(ChannelWindowController.resetFontSize(_:)), "0"))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "[", [.command, .shift]))
        menu.addItem(item("Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "]", [.command, .shift]))
        menu.addItem(item("Move Tab to New Window", #selector(NSWindow.moveTabToNewWindow(_:))))
        menu.addItem(item("Merge All Windows", #selector(NSWindow.mergeAllWindows(_:))))
        menu.addItem(.separator())
        let channels = NSMenuItem(title: "Tune to Channel", action: nil, keyEquivalent: "")
        let channelsMenu = NSMenu(title: "Tune to Channel")
        for n in 1...9 {
            let title = n == 9 ? "Last Channel" : "Channel \(n)"
            channelsMenu.addItem(item(title, #selector(AppDelegate.selectChannel(_:)), "\(n)", tag: n))
        }
        channels.submenu = channelsMenu
        menu.addItem(channels)
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
}
