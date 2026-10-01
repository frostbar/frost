import AppKit

/// Minimal main menu. Frost is an accessory app, so its menus never appear in the menu bar, but key equivalents are
/// still dispatched through the main menu: without one, shortcuts like Command-W, Command-Q, Command-C and Command-V
/// do nothing in the settings and onboarding windows.
@MainActor
enum MainMenu {
    /// - Parameters:
    ///   - target: Target of the About, Check for Updates and Settings items (must implement `showAbout(_:)` /
    ///     `checkForUpdates(_:)` / `showSettings(_:)`).
    static func make(target: AnyObject) -> (menu: NSMenu, windowsMenu: NSMenu) {
        let main = NSMenu()

        let app = submenu(in: main, title: "Frost")
        app.addItem(item("About Frost", #selector(AppDelegate.showAbout(_:)), target: target))
        app.addItem(item("Check for Updates…", #selector(AppDelegate.checkForUpdates(_:)), target: target))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), key: ",", target: target))
        app.addItem(.separator())
        app.addItem(item("Hide Frost", #selector(NSApplication.hide(_:)), key: "h"))
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h",
                         modifiers: [.command, .option]))
        app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(item("Quit Frost", #selector(NSApplication.terminate(_:)), key: "q"))

        let edit = submenu(in: main, title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), key: "z"))
        edit.addItem(item("Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), key: "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), key: "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), key: "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), key: "a"))

        let window = submenu(in: main, title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        window.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), key: "w"))

        return (main, window)
    }

    private static func submenu(in main: NSMenu, title: LocalizedStringResource) -> NSMenu {
        let title = String(localized: title)
        let menu = NSMenu(title: title)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        main.addItem(holder)
        return menu
    }

    /// A nil `target` dispatches through the responder chain (window, text field, NSApp).
    private static func item(_ title: LocalizedStringResource, _ action: Selector, key: String = "",
                             modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: title), action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        item.target = target
        return item
    }
}
