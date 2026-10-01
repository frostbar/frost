import AppKit
import Observation
import SwiftUI

/// Onboarding state that must survive closing and reopening the window.
@Observable
@MainActor
final class OnboardingSession {
    /// The user clicked Grant for Screen Recording (the relaunch notice shows until the grant takes effect).
    var screenRecordingRequested = false
}

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

    /// Written before relaunching: the new process reopens onboarding so the user sees the result and the next step.
    private static let resumeAfterRelaunchKey = "resumeOnboardingAfterRelaunch"

    /// Reads and clears the resume-onboarding-after-relaunch flag.
    static func consumeResumeRequest(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.bool(forKey: resumeAfterRelaunchKey) else { return false }
        defaults.removeObject(forKey: resumeAfterRelaunchKey)
        return true
    }

    private let model: AppModel
    private let session = OnboardingSession()
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
            grantScreenRecording: { [weak self] in
                guard let self else { return }
                self.session.screenRecordingRequested = true
                self.model.permissions.requestScreenRecording()
            },
            relaunch: { [weak self] in self?.relaunch() },
            dismiss: { [weak self] in self?.window.close() },
            openLayoutEditor: { [weak self] in
                guard let self else { return }
                self.window.close()
                self.model.openSettings(tab: .layout)
            })
        let root = OnboardingRootView(session: session, actions: actions)
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

    /// Relaunches Frost: a shell child process waits for this process to exit, then `open`s the app bundle (opening it
    /// directly would just activate the still-running old instance).
    /// launchd adopts the child once this process exits; it waits at most 10 seconds.
    private func relaunch() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: Self.resumeAfterRelaunchKey)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            #"i=0; while kill -0 "$0" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done; exec /usr/bin/open "$1""#,
            String(ProcessInfo.processInfo.processIdentifier),
            Bundle.main.bundlePath,
        ]
        do {
            try process.run()
        } catch {
            defaults.removeObject(forKey: Self.resumeAfterRelaunchKey)
            NSSound.beep()
            return
        }
        NSApp.terminate(nil)
    }
}
