import AppKit
import SwiftUI

/// The permissions onboarding window (a reused singleton), styled like the settings window: transparent title bar,
/// content extending under it, blurred background, 520x560, centered.
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

    private init(model: AppModel) {
        self.model = model
        window = NSWindow(contentRect: NSRect(origin: .zero, size: OnboardingView.size),
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
            relaunch: { AppRelauncher.relaunch() },
            dismiss: { [weak self] in self?.window.close() },
            openLayoutEditor: { [weak self] in
                guard let self else { return }
                self.window.close()
                self.model.openSettings(tab: .layout)
            })
        let root = OnboardingRootView(actions: actions)
            .environment(model)
            .background(VisualEffectBackground().ignoresSafeArea())
            .ignoresSafeArea()
        let hostingView = NSHostingView(rootView: root)
        // Fixed window size: do not let SwiftUI's ideal size resize the window.
        hostingView.sizingOptions = []
        window.contentView = hostingView
        // Content extends under the title bar: make the whole window (not just the part below it) 520x560.
        window.setFrame(NSRect(origin: .zero, size: OnboardingView.size), display: false)
        window.delegate = self
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
