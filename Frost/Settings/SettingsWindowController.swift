import AppKit
import SwiftUI

/// The settings window (a reused singleton): transparent title bar, content extends under it, 640x520.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private static var shared: SettingsWindowController?

    /// Opens (creating if needed) the settings window and brings Frost to the front; switches to `tab` if non-nil.
    static func show(model: AppModel, tab: SettingsTab? = nil) {
        let controller = shared ?? SettingsWindowController(model: model, initialTab: tab ?? .layout)
        shared = controller
        if let tab, controller.navigation.tab != tab {
            withAnimation(.bouncy) { controller.navigation.tab = tab }
        }
        controller.show()
    }

    static let contentSize = NSSize(width: 640, height: 520)

    private let model: AppModel
    /// Layout editor state, living as long as the window. The editor is active (menu bar in editing state) only while
    /// the window is open and the Layout tab is selected.
    private let layoutEditor: LayoutEditorModel
    private let navigation: SettingsNavigation
    let window: NSWindow
    private var hasBeenShown = false
    /// After `show()` the window is not key yet; until it is, do not start editing (the window may be behind another
    /// app, so the user would not see the editor while the whole menu bar is expanded).
    private var isAwaitingKey = false

    init(model: AppModel, initialTab: SettingsTab = .layout) {
        self.model = model
        layoutEditor = LayoutEditorModel(model: model)
        navigation = SettingsNavigation(tab: initialTab)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.contentSize),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = String(localized: "Frost Settings", comment: "Settings window title")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Do not move the window by dragging its background: dragging an icon tile in the layout editor could be taken
        // as a window drag. The title bar is still draggable.
        window.isMovableByWindowBackground = false
        // The empty compact toolbar only raises the title bar to 40 pt so the traffic lights and the segmented control
        // line up vertically (`.unified` puts a backdrop view over the title bar that intercepts clicks;
        // `.unifiedCompact` does not).
        window.toolbar = NSToolbar(identifier: "FrostSettings")
        window.toolbarStyle = .unifiedCompact
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.contentMinSize = Self.contentSize
        let hostingView = NSHostingView(rootView: SettingsRootView(navigation: navigation)
            .environment(model)
            .environment(layoutEditor))
        // Fixed window size: do not let SwiftUI's ideal size resize the window.
        hostingView.sizingOptions = [.minSize]
        window.contentView = hostingView
        window.setContentSize(Self.contentSize)
        super.init()
        window.delegate = self
    }

    func show() {
        if !hasBeenShown {
            window.center()
            hasBeenShown = true
        }
        WindowActivation.bringToFront(window)
        // Activation is asynchronous: the window usually becomes key on the next event loop pass (editing then starts
        // in `windowDidBecomeKey`).
        if window.isKeyWindow {
            isAwaitingKey = false
            layoutEditor.setWindowVisible(true)
        } else {
            isAwaitingKey = true
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the settings window ends editing and collapses the menu bar; if a move is in progress the editor
        // collapses after it finishes. (SwiftUI does not always send onDisappear to the Layout tab on close, so the
        // window reports it directly.)
        isAwaitingKey = false
        layoutEditor.setWindowVisible(false)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        // The editor is not visible while minimized: same as closing, end editing and collapse the menu bar.
        layoutEditor.setWindowVisible(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        // If the Layout tab is still selected after restoring, re-enter editing (the editor decides based on the tab).
        layoutEditor.setWindowVisible(true)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if isAwaitingKey {
            // The newly opened window actually reached the front: only now start editing (if the Layout tab is selected).
            isAwaitingKey = false
            layoutEditor.setWindowVisible(true)
            return
        }
        // The user switched back from another app: with the Layout tab active, the editor does one full refresh (icons
        // may have changed in the meantime).
        layoutEditor.windowDidBecomeKey()
    }
}
