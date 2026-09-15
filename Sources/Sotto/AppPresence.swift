import AppKit

/// Everything that makes Sotto look like an ordinary application rather than a background agent:
/// a Dock icon, a Command-Tab entry, and a main menu.
///
/// The activation policy is also set here rather than relying on the Info.plist alone, so the
/// Dock tile and the Command-Tab entry exist from the first instant instead of appearing after a
/// runtime transition that the Dock sometimes misses.
@MainActor
enum AppPresence {
    static func install() {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = mainMenu()
    }

    // An Edit menu is not decoration: without it the search field and the prompt playground get no
    // Command-C, Command-V, or Command-A, because those are menu-driven on macOS.
    private static func mainMenu() -> NSMenu {
        let menu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Sotto", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Sotto", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return menu
    }
}
