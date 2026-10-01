import AppKit

/// Brings Frost's regular windows (settings, onboarding) in front of all apps.
///
/// Frost is an LSUIElement (accessory) app, and these windows are usually opened from the status item menu (Settings...
/// in the snowflake's context menu), the Frost Bar or onboarding, while another app is frontmost. Cooperative activation
/// (`NSApp.activate()`, macOS 14+) is denied on these paths: by the time a status item menu item is chosen the menu has
/// closed, so the system no longer treats it as user intent to activate Frost, and the window stays behind the frontmost
/// app's windows (3/3 on real hardware, also reproduced in the VM with HID-level clicks). In VM tests (macOS 26.6) only
/// `activate(ignoringOtherApps: true)` activated reliably.
@MainActor
enum WindowActivation {
    static func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
