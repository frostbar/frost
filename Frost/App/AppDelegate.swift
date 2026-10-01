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

    /// If a move transaction (editor drag and drop, Frost Bar click forwarding or move-back) is in flight, defer
    /// termination until it finishes; otherwise an icon temporarily moved into the Visible section would stay there
    /// (the system has already remembered its new position). Waits at most 5 seconds.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, let frostBar, model.mover.isBusy || frostBar.hasPendingWork else { return .terminateNow }
        FrostLog.app.notice("deferring termination until the in-flight move finishes")
        Task { @MainActor in
            var finished = false
            Task { @MainActor in
                await frostBar.prepareForTermination()
                while model.mover.isBusy {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                finished = true
            }
            let clock = ContinuousClock()
            let deadline = clock.now + Self.terminationGrace
            while !finished, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if !finished { FrostLog.app.error("terminating with a move still in progress") }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private static let terminationGrace: Duration = .seconds(5)

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
