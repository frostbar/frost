import CoreGraphics
import Foundation

/// Decisions for handing activation off during click forwarding (macOS 14+ cooperative activation).
///
/// Problem: the user clicks Frost's non-activating panel (Frost Bar), then Frost clicks the target item with synthetic
/// events / AXPress. The system doesn't treat that click as the user's intent toward the target app, so the target
/// app's cooperative `NSApp.activate()` (without `ignoringOtherApps`) is refused; it never becomes the frontmost app,
/// so its transient popover never gets "app resigned active" and doesn't close on an outside click.
///
/// Hand-off: at the moment it handles the user's click on Frost Bar, Frost is allowed to activate itself
/// (`NSApp.activate()`); when the forwarded click opens a non-menu presentation, Frost hands activation to the target
/// app with `NSApp.yieldActivation(to:)` + `activate(from:)`. Menus are not handed off: activating the target app
/// during menu tracking (e.g. by honouring its previously refused `activate()` request) closes the menu immediately.
/// When the presentation ends and Frost still holds activation (menus, items with no action), it is handed back to the
/// previous frontmost app.
/// If Frost was already frontmost before the hand-off (settings window is key), it returns to Frost afterwards: once
/// the target app's popover closes it gives up activation and the system hands frontmost to the next **regular** app
/// (Frost, being LSUIElement, isn't a candidate), pushing the settings window behind it (observed on real hardware).
/// Except when the user clicked another app themselves in the meantime.
public enum ActivationHandOffPolicy {
    public enum Decision: Equatable, Sendable {
        case handOff
        case skip(SkipReason)
    }

    public enum SkipReason: Equatable, Sendable {
        /// Unknown owner (AX didn't resolve a pid): no one to yield to.
        case unknownOwner
        /// Frost's own item.
        case ownProcess
        /// Apple system items (`com.apple.*`, including Control Center's modules): their presentations don't depend on
        /// app activation (the HID click path is enough), so their behaviour is left unchanged.
        case systemItem
        /// The target process doesn't exist, has quit, or can't be activated (`activationPolicy == .prohibited`).
        case targetNotActivatable
        /// Frost isn't frontmost but has visible regular windows (settings / onboarding): activating Frost would bring
        /// them to the front, an obvious focus steal. No hand-off then; the "click outside" fallback
        /// (`OutsideClickDismissal`) closes the presentation.
        case wouldRaiseFrostWindows
    }

    /// - Parameters:
    ///   - ownerPID / bundleID: owner of the clicked item (`MenuBarItem.pid` / `bundleID`).
    ///   - ownPID: Frost's own pid.
    ///   - targetActivatable: the target `NSRunningApplication` exists, hasn't quit, `activationPolicy != .prohibited`.
    ///   - frostIsActive: activating Frost has no visible side effect when it is already frontmost (e.g. settings
    ///     window is key).
    ///   - frostHasVisibleWindows: Frost has a visible, non-minimized window that can become main.
    public static func decide(ownerPID: pid_t?, bundleID: String?, ownPID: pid_t, targetActivatable: Bool,
                              frostIsActive: Bool, frostHasVisibleWindows: Bool) -> Decision {
        guard let ownerPID else { return .skip(.unknownOwner) }
        guard ownerPID != ownPID else { return .skip(.ownProcess) }
        if isSystemItem(bundleID: bundleID) { return .skip(.systemItem) }
        guard targetActivatable else { return .skip(.targetNotActivatable) }
        if !frostIsActive, frostHasVisibleWindows { return .skip(.wouldRaiseFrostWindows) }
        return .handOff
    }

    /// Whether Frost really is the frontmost app (`frostIsActive` for `decide` / `handBack`). Looks only at the
    /// frontmost app (`NSWorkspace.frontmostApplication`), not `NSApp.isActive`: Frost Bar is a non-activating panel,
    /// and while it is key `NSApp.isActive` is true even though the frontmost app is still the previous one (measured
    /// in the VM, macOS 26.6). Judging by `NSApp.isActive` would skip activating Frost and record "already frontmost
    /// before the hand-off", so the whole hand-off would fall through.
    public static func isFrostActive(frontmostPID: pid_t?, ownPID: pid_t) -> Bool {
        frontmostPID == ownPID
    }

    /// Apple system items: same prefix as `ItemClicker`'s HID click check.
    public static func isSystemItem(bundleID: String?) -> Bool {
        bundleID?.hasPrefix(ItemClicker.systemBundleIDPrefix) ?? false
    }

    public enum HandBack: Equatable, Sendable {
        /// Do nothing: Frost no longer holds activation (the target app took it, or the user clicked another app).
        case none
        /// Hand activation back to the app that was frontmost before the hand-off (its pid).
        case activatePrevious(pid_t)
        /// The previous frontmost app is unknown / has quit / is Frost: just deactivate Frost and let the system pick
        /// the next app.
        case deactivate
        /// Frost was frontmost before the hand-off, isn't now, and the user didn't choose another app: reactivate Frost
        /// (the settings window comes back to the front).
        case reactivateFrost
    }

    /// Hand-back decision when forwarding ends (presentation closed, nothing presented, gave up waiting, error).
    /// - Parameters:
    ///   - frostIsActive: whether Frost is still frontmost right now.
    ///   - frostWasActive: Frost was already frontmost before the hand-off (then there's nothing to hand back).
    ///   - previousPID: the frontmost app before the hand-off; `previousIsRunning` false means it has quit.
    ///   - userChoseOtherApp: the user clicked another app during the hand-off (`isClickChoosingAnotherApp`).
    public static func handBack(frostIsActive: Bool, frostWasActive: Bool, previousPID: pid_t?,
                                previousIsRunning: Bool, ownPID: pid_t, userChoseOtherApp: Bool) -> HandBack {
        if frostWasActive {
            return frostIsActive || userChoseOtherApp ? .none : .reactivateFrost
        }
        guard frostIsActive else { return .none }
        guard let previousPID, previousPID != ownPID, previousIsRunning else { return .deactivate }
        return .activatePrevious(previousPID)
    }

    /// Whether a mouse down during the hand-off (CG coordinates, global monitor: not in Frost's windows) means the user
    /// is choosing another app: not when it lands on any display's menu bar (an empty spot closing the popover, another
    /// icon) or on the target app's own windows (the popover); yes on other apps' windows, the Dock, the desktop.
    /// `topWindowOwnerPID` is the owner of the topmost window at that point (below the menu bar layer), nil when
    /// there's no window.
    public static func isClickChoosingAnotherApp(at point: CGPoint, menuBars: [CGRect], topWindowOwnerPID: pid_t?,
                                                 targetPID: pid_t, ownPID: pid_t) -> Bool {
        if menuBars.contains(where: { $0.contains(point) }) { return false }
        guard let owner = topWindowOwnerPID else { return true }
        return owner != targetPID && owner != ownPID
    }
}
