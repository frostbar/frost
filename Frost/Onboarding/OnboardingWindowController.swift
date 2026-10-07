import AppKit
import SwiftUI

/// The permissions onboarding window (a reused singleton), styled like the settings window: transparent title bar,
/// content extending under it, blurred background, 520 pt wide and as tall as its content, centered.
///
/// The height follows the content like the settings window follows its tab: measured from SwiftUI before the window
/// first shows, and again whenever the content's height changes (a notice appearing), animating the window's frame
/// while its top edge stays put. The content is pinned to the top at its own height, so it is never laid out again or
/// moved by the window's animation.
///
/// Polls permissions every second while shown (users do not necessarily switch back to Frost after granting access in
/// System Settings); closing it counts as completing onboarding.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private static var shared: OnboardingWindowController?

    /// Opens (creating if needed) the onboarding window and brings Frost to the front.
    static func show(model: AppModel) {
        let controller = shared ?? OnboardingWindowController(model: model)
        shared = controller
        controller.show()
    }

    /// The onboarding window, if it has been created (it is reused, so it may be closed).
    static var window: NSWindow? { shared?.window }

    private let model: AppModel
    let window: NSWindow
    private var hasBeenShown = false
    private var isPolling = false
    /// The SwiftUI content, pinned to the top of the window's content view at `heightConstraint`.
    private var hostingController: NSHostingController<AnyView>?
    private var heightConstraint: NSLayoutConstraint?
    /// The content height the window was last sized for.
    private var fittedHeight: CGFloat?
    private var fitTask: Task<Void, Never>?

    /// Duration of the window's height animation (the settings window's).
    private static let resizeDuration = SettingsWindowController.resizeDuration

    private init(model: AppModel) {
        self.model = model
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: OnboardingView.width, height: 560),
                          styleMask: [.titled, .closable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = String(localized: "Welcome to Frost", comment: "Onboarding window title")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init()

        let actions = OnboardingActions(
            grantAccessibility: { [weak self] in self?.model.permissions.requestAccessibility() },
            grantScreenRecording: { [weak self] in self?.model.permissions.requestScreenRecording() },
            openScreenRecordingSettings: { [weak self] in self?.model.permissions.openScreenRecordingSettings() },
            relaunch: { AppRelauncher.relaunch() },
            dismiss: { [weak self] in self?.window.close() },
            openLayoutEditor: { [weak self] in
                guard let self else { return }
                self.window.close()
                self.model.openSettings(tab: .layout)
            })
        let root = OnboardingRootView(actions: actions, onHeightChange: { [weak self] _ in self?.contentHeightChanged() })
            .environment(model)
        let hosting = NSHostingController(rootView: AnyView(root))
        // The window's size comes from the measured content height, not from the hosting controller; no safe area
        // insets: the content extends under the transparent title bar.
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        hostingController = hosting
        // The blurred background is the window's content view, so it covers the window at every height of its
        // animation, also below the content while the window shrinks.
        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        let hosted = hosting.view
        hosted.translatesAutoresizingMaskIntoConstraints = false
        hosted.clipsToBounds = true
        background.addSubview(hosted)
        let height = hosted.heightAnchor.constraint(equalToConstant: 560)
        heightConstraint = height
        NSLayoutConstraint.activate([
            hosted.topAnchor.constraint(equalTo: background.topAnchor),
            hosted.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            height,
        ])
        window.contentView = background
        window.delegate = self
        fitToContent(animated: false)
    }

    /// The content's ideal height for the current state (SwiftUI's layout, not the frame of an animation in progress).
    private func measuredContentHeight() -> CGFloat? {
        guard let hostingController else { return nil }
        let height = hostingController.sizeThatFits(in: CGSize(width: OnboardingView.width, height: 4000)).height
        return height.isFinite && height > 0 ? height.rounded(.up) : nil
    }

    /// SwiftUI reported a new content height (once per frame while it animates): resize once, after the update that
    /// reported it, to the final height.
    private func contentHeightChanged() {
        guard fitTask == nil else { return }
        fitTask = Task { @MainActor [weak self] in
            self?.fitTask = nil
            self?.fitToContent(animated: true)
        }
    }

    /// Gives the window the content's height (it spans the whole window, title bar included), keeping its top edge and
    /// width; animated like the settings window when visible and Reduce Motion is off.
    private func fitToContent(animated: Bool) {
        guard let height = measuredContentHeight(), height != fittedHeight else { return }
        fittedHeight = height
        heightConstraint?.constant = height
        var frame = window.frame
        frame.origin.y += frame.height - height
        frame.size = CGSize(width: OnboardingView.width, height: height)
        guard animated, window.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            window.setFrame(frame, display: window.isVisible)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.resizeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }
    }

    func show() {
        if !hasBeenShown {
            window.center()
            hasBeenShown = true
        }
        if !isPolling {
            isPolling = true
            model.permissions.refresh()
            model.permissions.startPolling()
        }
        // Onboarding often appears without the user clicking Frost: on first launch, or after relaunching from
        // onboarding (the new process is opened by a background shell while Finder / System Settings is frontmost).
        // Cooperative activation (`NSApp.activate()`) is not yielded by the frontmost app in these cases, leaving the
        // window non-key (dimmed buttons, Esc / Command-W do nothing); see `WindowActivation`.
        WindowActivation.bringToFront(window)
    }

    func windowWillClose(_ notification: Notification) {
        // Polling follows the window (SwiftUI does not always send onDisappear when the window closes, so it does not
        // live in the view).
        if isPolling {
            isPolling = false
            model.permissions.stopPolling()
        }
        model.preferences.hasCompletedOnboarding = true
    }
}
