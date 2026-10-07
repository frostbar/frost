import AppKit
import FrostCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var model: AppModel?
    private var frostBar: FrostBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        FrostLog.app.notice("Frost \(version, privacy: .public) launched")
        let model = AppModel(isMenuBarSupported: UnsupportedOS.isMenuBarSupported)
        self.model = model
        model.showSettings = { [unowned model] tab in SettingsWindowController.show(model: model, tab: tab) }
        let menus = MainMenu.make(target: self)
        guard model.isMenuBarSupported else {
            startUnsupported(model, menus: menus)
            return
        }
        model.openOnboarding = { [unowned model] in OnboardingWindowController.show(model: model) }
        let frostBar = FrostBarController(app: model)
        self.frostBar = frostBar
        model.toggleFrostBar = { [unowned frostBar] in frostBar.toggle(showAlwaysHidden: $0) }
        // A click forward closes the panel first and then waits for the mover: placement must yield to it too.
        model.newItems.isPaused = { [unowned frostBar] in frostBar.isOpen || frostBar.pendingActivation != nil }
        model.start()
        frostBar.warmUp()
        NSApp.mainMenu = menus.menu
        NSApp.windowsMenu = menus.windowsMenu
        // Reopen the window the user was granting Screen Recording in before the relaunch, and open onboarding on
        // first launch.
        let resume = RelaunchResume.consume()
        if case .settings(let rawTab) = resume {
            model.openSettings(tab: SettingsTab(rawValue: rawTab) ?? .about)
        }
        if resume == .onboarding || !model.preferences.hasCompletedOnboarding {
            model.openOnboarding()
        }
    }

    /// An unsupported macOS (`PlatformSupport`): Frost leaves the menu bar alone. No Frost Bar (so no live refresh,
    /// background captures or freeze frames), no new-item placement or section memory, no scanning, no separators: only
    /// the snowflake, whose menu shows the notice next to Settings…, Check for Updates… and Quit. Sparkle keeps running,
    /// so a release that supports this macOS can arrive. Permission onboarding doesn't run (permissions change
    /// nothing here); anything that would open it shows the notice in Settings → About instead, and
    /// `hasCompletedOnboarding` stays as it is for that release.
    private func startUnsupported(_ model: AppModel, menus: (menu: NSMenu, windowsMenu: NSMenu)) {
        FrostLog.app.notice("""
            macOS \(UnsupportedOS.versionDescription, privacy: .public) isn't supported: leaving the menu bar alone \
            (snowflake only)
            """)
        model.openOnboarding = { [unowned model] in model.openSettings(tab: .about) }
        model.start()
        NSApp.mainMenu = menus.menu
        NSApp.windowsMenu = menus.windowsMenu
        // Settings reopens after a relaunch it was waiting for; onboarding never opens by itself here.
        if case .settings(let rawTab) = RelaunchResume.consume() {
            model.openSettings(tab: SettingsTab(rawValue: rawTab) ?? .about)
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
    ///   about 4.5 s, below `terminationGrace`. A background capture whose item waits for a held mouse button to be moved
    ///   back waits at most `ObscuredCapturePolicy.shutdownHoldLimit`, then leaves it: its return was recorded before
    ///   the move out, and the next launch makes it (`SectionKeeper.pendingReturns`). After the grace period Frost
    ///   quits anyway, but never while a synthetic event sequence is being posted (`SyntheticEventGate`), so the
    ///   mouse-up and the cursor restore are never left pending.
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
        recordWindowToResume()
    }

    /// Screen Recording takes effect only in a new process: if the user is waiting on that grant (Frost's Relaunch
    /// button, or System Settings' "Quit & Reopen" quitting Frost), the next launch reopens the window they were in.
    private func recordWindowToResume() {
        guard let model else { return }
        var visible: [(window: NSWindow, resume: ResumeWindow)] = []
        if let window = OnboardingWindowController.window { visible.append((window, .onboarding)) }
        if let settings = SettingsWindowController.current {
            visible.append((settings.window, .settings(tab: settings.tab.rawValue)))
        }
        let ordered = NSApp.orderedWindows
        let frontToBack = visible
            .filter { $0.window.isVisible && !$0.window.isMiniaturized }
            .sorted { (ordered.firstIndex(of: $0.window) ?? .max) < (ordered.firstIndex(of: $1.window) ?? .max) }
            .map(\.resume)
        guard let window = RelaunchResume.windowToRestore(
            screenRecordingPending: model.permissions.screenRecordingNeedsRelaunch,
            visibleFrontToBack: frontToBack) else { return }
        RelaunchResume.record(window)
        FrostLog.app.notice("will reopen \(window.storedValue, privacy: .public) after the relaunch")
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

    // AppKit's own validation disables Hide / Hide Others / Show All for an accessory app (it can't be unhidden from
    // the Dock or the app switcher), so ⌘H did nothing. Frost unhides itself whenever it shows a window (Settings… in
    // the Frost icon's menu activates it), so hiding is safe; these actions are always enabled.

    @objc func hideFrost(_ sender: Any?) {
        NSApp.hide(sender)
    }

    @objc func hideOthers(_ sender: Any?) {
        NSApp.hideOtherApplications(sender)
    }

    @objc func showAll(_ sender: Any?) {
        NSApp.unhideAllApplications(sender)
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
