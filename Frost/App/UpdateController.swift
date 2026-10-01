import Foundation
import FrostCore
import Observation
import Sparkle

/// Sparkle automatic updates (`SPUStandardUpdaterController`). The feed URL and public key live in Info.plist
/// (`SUFeedURL` / `SUPublicEDKey`, see project.yml). Sparkle persists the automatic-check setting in UserDefaults
/// (`SUEnableAutomaticChecks`).
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
    }

    /// User-initiated check: shows Sparkle's update window if an update exists, otherwise reports that Frost is up to date.
    func checkForUpdates() {
        FrostLog.app.notice("user-initiated update check")
        controller.checkForUpdates(nil)
    }
}

/// Frost is a background (LSUIElement) app, so opt in to gentle reminders: Sparkle then places update windows from
/// scheduled checks behind other windows instead of stealing focus
/// (https://sparkle-project.org/documentation/gentle-reminders).
private final class UserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
