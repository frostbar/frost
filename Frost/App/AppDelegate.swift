import AppKit
import FrostCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var model: AppModel?
    private var frostBar: FrostBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        FrostLog.app.notice("Frost \(version, privacy: .public) launched")
        let model = AppModel()
        self.model = model
        model.showSettings = { [unowned model] tab in SettingsWindowController.show(model: model, tab: tab) }
        model.openOnboarding = { [unowned model] in OnboardingWindowController.show(model: model) }
        let frostBar = FrostBarController(app: model)
        self.frostBar = frostBar
        model.toggleFrostBar = { [unowned frostBar] in frostBar.toggle(showAlwaysHidden: $0) }
        model.newItems.isPaused = { [unowned frostBar] in frostBar.isOpen }
        model.start()
        frostBar.warmUp()
        let menus = MainMenu.make(target: self)
        NSApp.mainMenu = menus.menu
        NSApp.windowsMenu = menus.windowsMenu
        // Open onboarding on first launch, or after onboarding asked to relaunch.
        let resumeOnboarding = OnboardingWindowController.consumeResumeRequest()
        if resumeOnboarding || !model.preferences.hasCompletedOnboarding {
            model.openOnboarding()
        }
    }

    // MARK: - Termination

    /// Quitting must never leave an icon temporarily moved into the Visible section (the system has already
    /// remembered its new position), nor exit in the middle of a ⌘-drag.
    ///
    /// - First `ItemMover.beginShutdown()`: from now on no new move transaction can start (a queued editor drop, a
    ///   new-item placement, …); only the move-back work below may.
    /// - If a transaction (editor drag and drop, Frost Bar click forwarding or move-back) or Frost Bar work is in
    ///   flight, defer termination: `FrostBarController.prepareForTermination` ends a forwarded click's wait, moves
    ///   the icon back and runs a pending move-back retry; then the reply is sent in the same main-actor turn that
    ///   observes the mover idle, so nothing can start in between.
    /// - While shutting down every move makes a single attempt (`ItemMover.shutdownMaxAttempts`): the worst case
    ///   (an interrupted move-out, a move-back to the anchor then to the section boundary, and one retry of both) is
    ///   about 4.5 s, below `terminationGrace`. After the grace period Frost quits anyway, but never while a
    ///   synthetic event sequence is being posted (`SyntheticEventGate`), so the mouse-up and the cursor restore are
    ///   never left pending.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, let frostBar else { return .terminateNow }
        model.mover.beginShutdown()
        guard model.mover.isBusy || frostBar.hasPendingWork else { return .terminateNow }
        FrostLog.app.notice("deferring termination until the in-flight move finishes")
        Task { @MainActor in
            let preparation = TerminationPreparation()
            Task { @MainActor in
                await frostBar.prepareForTermination()
                preparation.isFinished = true
            }
            let clock = ContinuousClock()
            let deadline = clock.now + Self.terminationGrace
            while !(preparation.isFinished && !model.mover.isBusy) {
                guard clock.now < deadline else {
                    FrostLog.app.error("terminating with a move still in progress")
                    break
                }
                try? await Task.sleep(for: Self.terminationPoll)
            }
            // Never exit between a synthetic mouse-down and its mouse-up / cursor restore (posting takes < 0.2 s).
            let postDeadline = clock.now + .seconds(1)
            while SyntheticEventGate.isPosting, clock.now < postDeadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Captures held back by the disk cache's write throttle (dynamic icons) are written now, so the next launch
        // starts from the newest ones.
        model?.capturer.flushDiskCache(synchronously: true)
    }

    private static let terminationGrace: Duration = .seconds(6)
    private static let terminationPoll: Duration = .milliseconds(20)

    // MARK: - Main menu

    @objc func showAbout(_ sender: Any?) {
        model?.openSettings(tab: .about)
    }

    @objc func showSettings(_ sender: Any?) {
        model?.openSettings()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        model?.updates.checkForUpdates()
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates(_:)) {
            return model?.updates.canCheckForUpdates ?? false
        }
        return true
    }
}

/// Whether `FrostBarController.prepareForTermination` has finished (set from the task that runs it).
@MainActor
private final class TerminationPreparation {
    var isFinished = false
}
