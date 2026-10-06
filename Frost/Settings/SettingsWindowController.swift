import AppKit
import SwiftUI

/// The settings window (a reused singleton) in the standard macOS settings style: an `NSTabViewController` with toolbar
/// tabs (icon and label, the selected one highlighted), the window title following the selected tab, fixed size.
///
/// Each tab is its own hosting controller living as long as the window, so switching tabs only swaps views (with a
/// short cross-fade, instant under Reduce Motion): no window resize and no SwiftUI rebuild of the tab's content.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private static var shared: SettingsWindowController?

    /// Opens (creating if needed) the settings window and brings Frost to the front; switches to `tab` if non-nil.
    static func show(model: AppModel, tab: SettingsTab? = nil) {
        // Start reading cached item images now, before the Layout tab is shown, so its tiles have them from the first
        // frame instead of showing app-icon placeholders that swap a moment later.
        if model.permissions.screenRecording {
            let capturer = model.capturer, items = model.scanner.items
            Task { await capturer.preloadCached(items) }
        }
        let controller = shared ?? SettingsWindowController(model: model, initialTab: tab ?? SettingsTab.lastSelected)
        shared = controller
        if let tab { controller.select(tab) }
        controller.show()
    }

    /// The settings window, if it has been created (it is reused, so it may be closed), and its selected tab.
    static var current: (window: NSWindow, tab: SettingsTab)? {
        guard let shared else { return nil }
        let index = shared.tabs.selectedTabViewItemIndex
        guard SettingsTab.allCases.indices.contains(index) else { return nil }
        return (shared.window, SettingsTab.allCases[index])
    }

    /// Size of the tab content area below the toolbar (the same for every tab): tall enough for every tab's content
    /// without scrolling at the default text size, in English and zh-Hans. The tallest is Behavior in English while
    /// permissions are missing (its display mode card then adds a notice): 566 pt measured in the VM.
    static let contentSize: NSSize = {
        var size = NSSize(width: 640, height: 570)
        #if DEBUG
        // `FROST_TEST_SETTINGS_HEIGHT=<pt>` (VM testing only): another content height, e.g. small enough for the
        // tabs to scroll, or tall enough to measure their full content.
        if let value = ProcessInfo.processInfo.environment["FROST_TEST_SETTINGS_HEIGHT"], let height = Double(value) {
            size.height = height
        }
        #endif
        return size
    }()
    /// Delay between showing the Layout tab and starting the editor (expanding the menu bar, rescans, captures), so the
    /// switch renders first. After a fade the editor starts once the fade has ended (plus a short margin) instead.
    private static let editorStartDelay: Duration = .milliseconds(150)
    /// Margin between the end of the tab fade and the start (or end) of the editor.
    private static let editorStartMarginAfterFade: Duration = .milliseconds(60)

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
    /// Pending end of the editor after leaving the Layout tab: collapsing the menu bar (and the rescans that follow)
    /// during the cross-fade makes it hitch, so it waits for the fade to finish.
    private var editorStopTask: Task<Void, Never>?
    /// Why the editor is paused although the window is open (see `PauseReason`); empty = not paused.
    private var pauseReasons: Set<PauseReason> = []
    private var observers: [NSObjectProtocol] = []

    /// Situations in which nobody can see the editor, so the menu bar leaves editing mode (and the editor's refresh
    /// loop stops) like when the window is minimized.
    private enum PauseReason {
        /// Displays asleep, screen locked or another user's session (`UserPresenceMonitor`).
        case userAway
        /// Frost is hidden (Hide Frost, ⌘H, or another app's Hide Others).
        case appHidden
        /// The window is open but entirely covered (`NSWindow.occlusionState`), e.g. by a full-screen app.
        case occluded
    }

    init(model: AppModel, initialTab: SettingsTab = .layout) {
        self.model = model
        layoutEditor = LayoutEditorModel(model: model)
        tabs = SettingsTabViewController()
        tabs.tabStyle = .toolbar
        // No built-in transition: `SettingsTabViewController` runs its own cross-fade.
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
        if model.presence.isAway { pauseReasons.insert(.userAway) }
        if NSApp.isHidden { pauseReasons.insert(.appHidden) }
        for (name, hidden) in [(NSApplication.didHideNotification, true), (NSApplication.didUnhideNotification, false)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setPaused(.appHidden, hidden) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: UserPresenceMonitor.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.setPaused(.userAway, self.model.presence.isAway)
            }
        })
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
            controller = hosting(SettingsPane { LayoutEditorView() }, model, layoutEditor)
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
        // The container already places the content below the toolbar; no further insets from SwiftUI.
        controller.safeAreaRegions = []
        let container = SettingsTabContainerController(content: controller)
        container.view.frame.size = contentSize
        return container
    }

    private func select(_ tab: SettingsTab) {
        guard let index = SettingsTab.allCases.firstIndex(of: tab), tabs.selectedTabViewItemIndex != index else { return }
        tabs.selectedTabViewItemIndex = index
    }

    /// The selected tab changed (toolbar click or `select`): leaving Layout ends editing (collapsing the menu bar) once
    /// the cross-fade has finished; showing Layout starts editing shortly after the switch has rendered. Both wait
    /// for the fade so it never competes with the menu bar's rearrangement and the editor's rescans.
    private func tabDidChange(_ tab: SettingsTab) {
        guard tab != reportedTab else { return }
        reportedTab = tab
        SettingsTab.lastSelected = tab
        window.title = tab.title
        #if DEBUG
        FrameProbe.mark("tab-\(tab.rawValue)", in: window)
        #endif
        editorStartTask?.cancel()
        editorStartTask = nil
        editorStopTask?.cancel()
        editorStopTask = nil
        guard tab == .layout else {
            guard tabs.lastTransitionDuration > 0 else {
                layoutEditor.setTabSelected(false)
                return
            }
            let delay = Duration.seconds(tabs.lastTransitionDuration) + Self.editorStartMarginAfterFade
            editorStopTask = Task { [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self, self.reportedTab != .layout else { return }
                self.editorStopTask = nil
                self.layoutEditor.setTabSelected(false)
            }
            return
        }
        let delay = tabs.lastTransitionDuration > 0
            ? .seconds(tabs.lastTransitionDuration) + Self.editorStartMarginAfterFade
            : Self.editorStartDelay
        editorStartTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
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
        if window.isKeyWindow, pauseReasons.isEmpty {
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

    func windowDidChangeOcclusionState(_ notification: Notification) {
        // Only an open, non-minimized window counts as occluded (closing and minimizing are handled on their own).
        let occluded = window.isVisible && !window.isMiniaturized && !window.occlusionState.contains(.visible)
        setPaused(.occluded, occluded)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        // If the Layout tab is still selected after restoring, re-enter editing (the editor decides based on the tab).
        guard pauseReasons.isEmpty else { return }
        layoutEditor.setWindowVisible(true)
    }

    /// Pauses the editor (ends editing, collapsing the menu bar, and stops its refreshes) while any pause reason holds;
    /// once none does, resumes it if the window is still open and not minimized: right away if the window is key,
    /// otherwise once it becomes key (as after `show()`: the user may not be looking at it).
    private func setPaused(_ reason: PauseReason, _ paused: Bool) {
        let wasPaused = !pauseReasons.isEmpty
        if paused { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        let isPaused = !pauseReasons.isEmpty
        guard wasPaused != isPaused else { return }
        if isPaused {
            layoutEditor.setWindowVisible(false)
            return
        }
        guard window.isVisible, !window.isMiniaturized else { return }
        if window.isKeyWindow {
            isAwaitingKey = false
            layoutEditor.setWindowVisible(true)
        } else {
            isAwaitingKey = true
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard pauseReasons.isEmpty else { return }
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

/// One tab's content, kept below the toolbar.
///
/// The window has a full-size content view (the shared translucent background extends under the transparent toolbar),
/// so a tab's view also spans the toolbar area. Left to SwiftUI, a tab's `ScrollView` would scroll its content up under
/// the toolbar, where it shows through the toolbar's tab labels. The hosted content is therefore pinned to the safe area
/// (the window's content layout rect) and clipped to it: nothing of a tab is ever drawn under the toolbar, and a tab
/// that scrolls passes under the scroll edge effect of `SettingsPane`'s top bar.
private final class SettingsTabContainerController: NSViewController {
    private let content: NSViewController

    init(content: NSViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let view = NSView(frame: NSRect(origin: .zero, size: SettingsWindowController.contentSize))
        addChild(content)
        let hosted = content.view
        hosted.translatesAutoresizingMaskIntoConstraints = false
        hosted.clipsToBounds = true
        view.addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            hosted.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosted.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.view = view
    }
}

/// Reports toolbar tab selections to the window controller and cross-fades between tabs.
///
/// The window's translucent background is one `NSVisualEffectView` behind all tabs, outside the fade: cross-fading
/// two behind-window materials visibly shifts the tint mid-fade. The tabs themselves are transparent, so a switch is a
/// plain cross-fade of their content, run entirely by Core Animation: the incoming view is added (fully laid out and
/// drawn) and only the presentation opacities of the two views animate, so the main thread does no per-frame work and
/// the window never resizes. The outgoing view is removed when the fade ends.
private final class SettingsTabViewController: NSTabViewController {
    var onSelect: ((SettingsTab) -> Void)?

    /// Duration of the cross-fade (ease-in-out).
    static let fadeDuration: TimeInterval = 0.18

    /// Duration of the last switch's animation; 0 when it was instant (window not visible, Reduce Motion).
    private(set) var lastTransitionDuration: TimeInterval = 0
    /// Ends a cross-fade still running (another switch started): shows the incoming view at full opacity and removes
    /// the outgoing one.
    private var finishRunningFade: (() -> Void)?
    /// Identifies the running fade, so a stale completion does nothing.
    private var fadeGeneration = 0
    private static let fadeKey = "frost.tabFade"

    override func viewDidLoad() {
        super.viewDidLoad()
        let background = NSVisualEffectView(frame: view.bounds)
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        background.autoresizingMask = [.width, .height]
        view.addSubview(background, positioned: .below, relativeTo: nil)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String, let tab = SettingsTab(rawValue: id) {
            onSelect?(tab)
        }
    }

    // `NSTabViewController` routes every switch through this method (`transitionOptions` stays empty, so `super`
    // swaps the views instantly).
    override func transition(from fromViewController: NSViewController, to toViewController: NSViewController,
                             options: NSViewController.TransitionOptions = [],
                             completionHandler completion: (() -> Void)? = nil) {
        finishRunningFade?()
        let outgoing = fromViewController.view, incoming = toViewController.view
        guard let container = outgoing.superview, container.window?.isVisible == true,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            lastTransitionDuration = 0
            // AppKit calls the completion on the main thread (synchronously for an instant switch).
            nonisolated(unsafe) let completion = completion
            super.transition(from: fromViewController, to: toViewController, options: []) { completion?() }
            return
        }
        lastTransitionDuration = Self.fadeDuration

        // Add the incoming view and finish its layout and drawing now, so no first-render work lands inside the fade.
        incoming.wantsLayer = true
        outgoing.wantsLayer = true
        incoming.frame = container.bounds
        incoming.autoresizingMask = [.width, .height]
        container.addSubview(incoming, positioned: .above, relativeTo: outgoing)
        incoming.layoutSubtreeIfNeeded()
        incoming.displayIfNeeded()

        fadeGeneration += 1
        let generation = fadeGeneration
        finishRunningFade = { [weak self] in
            guard let self, self.fadeGeneration == generation else { return }
            self.fadeGeneration += 1
            self.finishRunningFade = nil
            outgoing.removeFromSuperview()
            outgoing.layer?.removeAnimation(forKey: Self.fadeKey)
            incoming.layer?.removeAnimation(forKey: Self.fadeKey)
            completion?()
        }

        // Model opacities stay 1 (the outgoing view is removed at the end); only the presentation fades.
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fadeGeneration == generation else { return }
                self.finishRunningFade?()
            }
        }
        outgoing.layer?.add(Self.fade(from: 1, to: 0), forKey: Self.fadeKey)
        incoming.layer?.add(Self.fade(from: 0, to: 1), forKey: Self.fadeKey)
        CATransaction.commit()
    }

    private static func fade(from: Float, to: Float) -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = fadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Hold the end value until the fade's completion removes the animation (no flash of the outgoing view).
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        return fade
    }
}
