import AppKit
import FrostCore
import Observation
import Sparkle

/// Sparkle automatic updates (`SPUStandardUpdaterController`). The feed URL and public key live in Info.plist
/// (`SUFeedURL` / `SUPublicEDKey`, see project.yml). Sparkle persists the automatic-check setting in UserDefaults
/// (`SUEnableAutomaticChecks`).
///
/// Gentle reminders (https://sparkle-project.org/documentation/gentle-reminders): Frost is an accessory app (no Dock
/// icon, no menu bar menus), so an update window Sparkle opens behind other apps' windows after a scheduled check could
/// go unnoticed indefinitely. When Sparkle would show a scheduled update in immediate focus (e.g. shortly after
/// launch) it does so itself; otherwise Frost records it in `pendingUpdateVersion` instead, which shows a badge on the
/// Frost icon and an "Update Available…" item in its menu; choosing it calls `checkForUpdates()`, which brings the
/// update window to the front. The reminder ends when the user attends to the update or the update session ends.
///
/// Modal alerts (e.g. "Update Error!" when a user-initiated check fails; Sparkle never shows errors of scheduled
/// background checks) run an app-modal session that blocks every other Frost window, the Frost icon included. Frost
/// brings the alert to the front when it appears and whenever the user clicks the Frost icon while it is up, so the
/// click is never simply dead and the alert can't hide behind other apps' windows.
///
/// For testing, `defaults write dev.frost.Frost SUFeedURL <url>` points it at a local feed (user defaults take
/// precedence over Info.plist).
@Observable
@MainActor
final class UpdateController {
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private let userDriverDelegate = UserDriverDelegate()
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    /// Whether a check can start now (false while checking, downloading or installing). Enables "Check for Updates...".
    private(set) var canCheckForUpdates = false

    /// The version of an update found by a scheduled check that is waiting for the user's attention (gentle
    /// reminder); nil when there is none.
    private(set) var pendingUpdateVersion: String?

    /// Whether to check for updates automatically in the background once a day.
    var automaticallyChecksForUpdates: Bool {
        didSet {
            guard updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    private var updater: SPUUpdater { controller.updater }

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                  userDriverDelegate: userDriverDelegate)
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        canCheckForUpdates = controller.updater.canCheckForUpdates
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            let value = change.newValue ?? false
            MainActor.assumeIsolated { self?.canCheckForUpdates = value }
        }
        userDriverDelegate.onReminder = { [weak self] version in
            FrostLog.app.notice("update \(version, privacy: .public) available (scheduled check); showing a reminder")
            self?.pendingUpdateVersion = version
        }
        userDriverDelegate.onReminderEnded = { [weak self] in
            guard let self, self.pendingUpdateVersion != nil else { return }
            self.pendingUpdateVersion = nil
        }
        userDriverDelegate.onModalAlert = { [weak self] shown in self?.modalAlertChanged(shown) }
    }

    @ObservationIgnored private var modalAlertMonitor: Any?

    private func modalAlertChanged(_ shown: Bool) {
        if let modalAlertMonitor {
            NSEvent.removeMonitor(modalAlertMonitor)
            self.modalAlertMonitor = nil
        }
        guard shown else { return }
        FrostLog.app.notice("Sparkle is showing a modal alert")
        NSApp.activate()
        // Clicks on the Frost icon can't do anything while the alert's modal session runs: bring the alert forward.
        // Local monitors still see events of a modal session (they run before dispatch).
        modalAlertMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                guard let alert = NSApp.modalWindow, event.window !== alert,
                      event.window?.className.contains("StatusBar") == true else { return }
                FrostLog.app.notice("Frost icon clicked while a Sparkle alert is up; bringing the alert to the front")
                NSApp.activate()
                alert.makeKeyAndOrderFront(nil)
            }
            return event
        }
    }

    /// User-initiated check: shows Sparkle's update window if an update exists, otherwise reports that Frost is up to
    /// date. With a pending reminder, brings that update's window to the front.
    func checkForUpdates() {
        FrostLog.app.notice("user-initiated update check")
        controller.checkForUpdates(nil)
    }
}

/// Sparkle's standard user driver delegate: opts in to gentle reminders and reports them to `UpdateController`.
/// Sparkle calls it on the main thread.
@MainActor
private final class UserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    /// A scheduled check found an update that Frost shows a reminder for (argument: its display version).
    var onReminder: ((String) -> Void)?
    /// The user attended to the update, or the update session ended.
    var onReminderEnded: (() -> Void)?
    /// A modal alert is about to be shown (true) / was dismissed (false).
    var onModalAlert: ((Bool) -> Void)?

    nonisolated func standardUserDriverWillShowModalAlert() {
        MainActor.assumeIsolated { self.onModalAlert?(true) }
    }

    nonisolated func standardUserDriverDidShowModalAlert() {
        MainActor.assumeIsolated { self.onModalAlert?(false) }
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Let Sparkle show a scheduled update only when it would do so in immediate focus; otherwise Frost shows a
    /// reminder (see `UpdateController`).
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                          andInImmediateFocus immediateFocus: Bool)
        -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                               forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated { self.onReminder?(version) }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { self.onReminderEnded?() }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { self.onReminderEnded?() }
    }
}
