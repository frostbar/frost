import AppKit
import FrostCore

/// Activation hand-off for forwarded clicks (macOS 14+ cooperative activation). Decisions live in
/// `ActivationHandOffPolicy`.
///
/// 1. `begin(for:)`: called while handling the user's click on a Frost Bar icon. It is a real user event, so Frost's
///    cooperative `NSApp.activate()` is allowed (Frost has no window to bring forward: the panel is closing, and no
///    hand-off happens while the settings / onboarding window is visible).
/// 2. `activateTarget()`: called once the forwarded click is known to have opened a **non-menu** presentation
///    (popover / panel). `NSApp.yieldActivation(to:)` + `activate(from: .current)` hand activation to the target app so
///    its transient popover closes on an outside click. We don't yield before the click: macOS keeps the target app's
///    earlier refused cooperative `activate()` request and honors it as soon as we yield; if the click opened a menu,
///    activating the app during menu tracking closes the menu at once (observed in the VM: after opening its popover via
///    the fallback path, forwarding its menu closed the menu after ~0.25 s and stole focus). Menus don't need the target
///    app active (they always close on an outside click), so only non-menu presentations are handed off.
/// 3. `finish()`: called when the presentation ends (any outcome, error, or cancellation). If Frost still holds
///    activation (the target app never took it, e.g. a menu or an item with no action), hand it back to the app that was
///    frontmost before. If Frost was frontmost before (settings window open) but isn't now, the system gave the front to
///    some other regular app after the target yielded; return to Frost, unless the user clicked another app in the
///    meantime (a global mouse monitor decides via `isClickChoosingAnotherApp`). Otherwise do nothing. Idempotent.
@MainActor
final class ActivationHandOff {
    private let target: NSRunningApplication
    private let previous: NSRunningApplication?
    private let frostWasActive: Bool
    private var finished = false
    private var targetActivated = false
    /// The user clicked another app's window, the Dock, or the desktop during the hand-off (only monitored when Frost
    /// was frontmost before the hand-off).
    private var userChoseOtherApp = false
    private var clickMonitor: Any?

    private init(target: NSRunningApplication, previous: NSRunningApplication?, frostWasActive: Bool) {
        self.target = target
        self.previous = previous
        self.frostWasActive = frostWasActive
        guard frostWasActive else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] event in
            MainActor.assumeIsolated { self?.mouseDown(event) }
        }
    }

    /// Returns nil when a hand-off doesn't apply (the reason is logged). Otherwise activates Frost right away.
    static func begin(for item: MenuBarItem?) -> ActivationHandOff? {
        guard let item else { return nil }
        let target = item.pid.flatMap { NSRunningApplication(processIdentifier: $0) }
        let activatable = target.map { !$0.isTerminated && $0.activationPolicy != .prohibited } ?? false
        let frostIsActive = isFrostActive()
        let decision = ActivationHandOffPolicy.decide(
            ownerPID: item.pid, bundleID: item.bundleID ?? target?.bundleIdentifier, ownPID: getpid(),
            targetActivatable: activatable, frostIsActive: frostIsActive,
            frostHasVisibleWindows: hasVisibleRegularWindows())
        guard case .handOff = decision, let target else {
            if case let .skip(reason) = decision, reason != .systemItem {
                FrostLog.activation.notice("activation hand-off skipped for item \(item.windowID): \(String(describing: reason), privacy: .public)")
            }
            return nil
        }
        let previous = NSWorkspace.shared.frontmostApplication
        if !frostIsActive { NSApp.activate() }
        return ActivationHandOff(target: target, previous: previous, frostWasActive: frostIsActive)
    }

    /// Called after a non-menu presentation is detected (only the first call has an effect).
    func activateTarget() {
        guard !finished, !targetActivated else { return }
        targetActivated = true
        // Activation is asynchronous; by now (after the move and click) Frost is usually frontmost. If it isn't, the
        // hand-off won't work, so log it for diagnosis.
        let bundleID = target.bundleIdentifier ?? "?"
        let pid = target.processIdentifier
        let frostActive = Self.isFrostActive() ? "yes" : "no"
        FrostLog.activation.notice("""
            yielding activation to \(bundleID, privacy: .public) (pid \(pid)) for its non-menu presentation; \
            Frost active: \(frostActive, privacy: .public)
            """)
        NSApp.yieldActivation(to: target)
        if !target.activate(from: .current, options: []) {
            FrostLog.activation.notice("activating \(bundleID, privacy: .public) was refused")
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        let decision = ActivationHandOffPolicy.handBack(
            frostIsActive: Self.isFrostActive(), frostWasActive: frostWasActive, previousPID: previous?.processIdentifier,
            previousIsRunning: previous.map { !$0.isTerminated } ?? false, ownPID: getpid(),
            userChoseOtherApp: userChoseOtherApp)
        switch decision {
        case .none:
            break
        case .activatePrevious:
            guard let previous else { return }
            NSApp.yieldActivation(to: previous)
            if !previous.activate(from: .current, options: []) {
                FrostLog.activation.notice(
                    "handing activation back to \(previous.bundleIdentifier ?? "?", privacy: .public) was refused; deactivating")
                NSApp.deactivate()
            }
        case .deactivate:
            NSApp.deactivate()
        case .reactivateFrost:
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
            FrostLog.activation.notice(
                "Frost was frontmost before the hand-off and \(front, privacy: .public) is now; returning to Frost")
            // Cooperative activation doesn't count as user intent here (the frontmost app didn't yield); see
            // `WindowActivation`.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Mouse-down in another app during the hand-off (global monitor; a click in Frost's own windows makes Frost
    /// frontmost, so it needs no check).
    private func mouseDown(_ event: NSEvent) {
        guard !finished, !userChoseOtherApp else { return }
        let point = ScreenCoordinates.cgPoint(fromAppKit: event.locationInWindow)
        let menuBars = NSScreen.screens.map { screen in
            let height = PanelPlacement.menuBarHeight(screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                                                      fallback: Self.fallbackMenuBarHeight)
            let frame = ScreenCoordinates.cgRect(fromAppKit: screen.frame)
            return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: height)
        }
        let owner = topWindowOwner(at: point)
        guard ActivationHandOffPolicy.isClickChoosingAnotherApp(at: point, menuBars: menuBars, topWindowOwnerPID: owner,
                                                                targetPID: target.processIdentifier, ownPID: getpid())
        else { return }
        userChoseOtherApp = true
        FrostLog.activation.notice("user clicked another app (pid \(owner ?? 0)) during the hand-off; not returning to Frost")
    }

    /// Some displays' `visibleFrame` doesn't exclude the menu bar (some external displays on real hardware, or an
    /// auto-hiding menu bar); assume a regular menu bar height.
    private static let fallbackMenuBarHeight: CGFloat = 30

    /// Owner of the topmost click-receiving window at a (CG) point: a regular window (layer 0), or a window of the target
    /// app / Frost at any layer (popovers sit at layer 101). Other system layers are skipped: on real hardware the Dock,
    /// Notification Center, etc. have transparent full-screen windows (layers 20 / 21) that aren't click targets.
    /// Returns nil over the Dock / desktop, where no such window exists (counts as choosing another app).
    private func topWindowOwner(at point: CGPoint) -> pid_t? {
        Self.topWindowOwner(at: point, considering: [target.processIdentifier, getpid()])
    }

    private static func topWindowOwner(at point: CGPoint, considering special: Set<pid_t>) -> pid_t? {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for window in info {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point) else { continue }
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            if layer == 0 || special.contains(pid) { return pid }
        }
        return nil
    }

    /// Frost is the frontmost app. Not `NSApp.isActive`: that is also true while the Frost Bar (a non-activating panel)
    /// is key; see `ActivationHandOffPolicy.isFrostActive`.
    private static func isFrostActive() -> Bool {
        ActivationHandOffPolicy.isFrostActive(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                              ownPID: getpid())
    }

    /// Frost has a visible, non-minimized window that can become main (settings, onboarding); activating Frost would
    /// bring it forward. Status item windows and the Frost Bar panel can't become main, so they don't count.
    private static func hasVisibleRegularWindows() -> Bool {
        NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.canBecomeMain }
    }
}
