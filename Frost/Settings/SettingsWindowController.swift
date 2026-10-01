import AppKit
import SwiftUI

/// The settings window (a reused singleton) in the standard macOS settings style: an `NSTabViewController` with toolbar
/// tabs (icon and label, the selected one highlighted), the window title following the selected tab, fixed size.
///
/// Each tab is its own hosting controller living as long as the window, so switching tabs only swaps views: no
/// transition, no window resize and no SwiftUI rebuild of the tab's content.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private static var shared: SettingsWindowController?

    /// Opens (creating if needed) the settings window and brings Frost to the front; switches to `tab` if non-nil.
    static func show(model: AppModel, tab: SettingsTab? = nil) {
        let controller = shared ?? SettingsWindowController(model: model, initialTab: tab ?? .layout)
        shared = controller
        if let tab { controller.select(tab) }
        controller.show()
    }

    /// Size of the tab content area below the toolbar (the same for every tab).
    static let contentSize = NSSize(width: 640, height: 470)
    /// Delay between showing the Layout tab and starting the editor (expanding the menu bar, rescans, captures), so the
    /// switch renders first.
    private static let editorStartDelay: Duration = .milliseconds(150)

    private let model: AppModel
    /// Layout editor state, living as long as the window. The editor is active (menu bar in editing state) only while
    /// the window is open and the Layout tab is selected.
    private let layoutEditor: LayoutEditorModel
    private let tabs: SettingsTabViewController
    let window: NSWindow
    private var hasBeenShown = false
    /// After `show()` the window is not key yet; until it is, do not start editing (the window may be behind another
    /// app, so the user would not see the editor while the whole menu bar is expanded).
    private var isAwaitingKey = false
    /// The tab the editor was last told about; nil before the first selection.
    private var reportedTab: SettingsTab?
    /// Pending start of the editor after switching to the Layout tab (see `editorStartDelay`).
    private var editorStartTask: Task<Void, Never>?

    init(model: AppModel, initialTab: SettingsTab = .layout) {
        self.model = model
        layoutEditor = LayoutEditorModel(model: model)
        tabs = SettingsTabViewController()
        tabs.tabStyle = .toolbar
        // Switch instantly: the default cross-fades the views.
        tabs.transitionOptions = []
        for tab in SettingsTab.allCases {
            let item = NSTabViewItem(viewController: Self.hostingController(for: tab, model: model,
                                                                             layoutEditor: layoutEditor))
            item.identifier = tab.rawValue
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil)
            tabs.addTabViewItem(item)
        }
        tabs.selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(of: initialTab) ?? 0

        window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .preference
        // Do not move the window by dragging its background: dragging an icon tile in the layout editor could be taken
        // as a window drag. The title bar is still draggable.
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.title = initialTab.title
        super.init()
        window.delegate = self
        tabs.onSelect = { [weak self] tab in self?.tabDidChange(tab) }
        tabDidChange(initialTab)
        #if DEBUG
        FrameProbe.installTrigger(window: window)
        #endif
    }

    private static func hostingController(for tab: SettingsTab, model: AppModel,
                                          layoutEditor: LayoutEditorModel) -> NSViewController {
        let controller: NSViewController
        switch tab {
        case .layout:
            // Space below the toolbar (the scrolling tabs pad inside their scroll views).
            controller = hosting(SettingsPane { LayoutEditorView().padding(.top, 12) }, model, layoutEditor)
        case .behavior: controller = hosting(SettingsPane { BehaviorView() }, model, layoutEditor)
        case .about: controller = hosting(SettingsPane { AboutView() }, model, layoutEditor)
        }
        // The window title follows the selected tab (the tab view controller propagates its selected child's title).
        controller.title = tab.title
        return controller
    }

    private static func hosting(_ view: some View, _ model: AppModel,
                                _ layoutEditor: LayoutEditorModel) -> NSViewController {
        let controller = NSHostingController(rootView: view.environment(model).environment(layoutEditor))
        // Fixed window size: the content's ideal size must not resize the window or animate it between tabs.
        controller.sizingOptions = []
        controller.view.frame.size = contentSize
        return controller
    }

    private func select(_ tab: SettingsTab) {
        guard let index = SettingsTab.allCases.firstIndex(of: tab), tabs.selectedTabViewItemIndex != index else { return }
        tabs.selectedTabViewItemIndex = index
    }

    /// The selected tab changed (toolbar click or `select`): leaving Layout ends editing (collapsing the menu bar)
    /// right away; showing Layout starts editing shortly after the switch has rendered.
    private func tabDidChange(_ tab: SettingsTab) {
        guard tab != reportedTab else { return }
        reportedTab = tab
        window.title = tab.title
        #if DEBUG
        FrameProbe.mark("tab-\(tab.rawValue)", in: window)
        #endif
        editorStartTask?.cancel()
        editorStartTask = nil
        guard tab == .layout else {
            layoutEditor.setTabSelected(false)
            return
        }
        editorStartTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.editorStartDelay) } catch { return }
            guard let self, self.reportedTab == .layout else { return }
            self.editorStartTask = nil
            self.layoutEditor.setTabSelected(true)
        }
    }

    func show() {
        if !hasBeenShown {
            fitWindowToContent()
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

    /// Sizes the window so the area below the toolbar is `contentSize` (the toolbar's height depends on the system).
    private func fitWindowToContent() {
        window.layoutIfNeeded()
        let chrome = window.frame.height - window.contentLayoutRect.height
        let size = NSSize(width: Self.contentSize.width, height: Self.contentSize.height + chrome)
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
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

/// Reports toolbar tab selections to the window controller.
private final class SettingsTabViewController: NSTabViewController {
    var onSelect: ((SettingsTab) -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String, let tab = SettingsTab(rawValue: id) {
            onSelect?(tab)
        }
    }
}
