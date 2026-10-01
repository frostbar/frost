import CoreGraphics
import Foundation

/// "Click outside to dismiss" fallback: when a **non-menu** presentation (popover / the app's own panel) opened via
/// click forwarding stays open after the user clicks outside it, Frost closes it.
///
/// Background: with cooperative activation the target app may not become the frontmost app (the
/// `ActivationHandOffPolicy` hand-off failed or was skipped). Its transient popover then never gets "app resigned
/// active", clicking elsewhere doesn't close it, and the icon stays in the visible section until the 60 s cap.
///
/// Flow (a pure state machine; the caller supplies time and window info):
/// 1. Mouse down outside the presentation windows and the item's status window → record the time.
/// 2. After the grace period (`grace`; the longer `ownerHandlesGrace` when the target app will handle this click
///    itself) the presentation is still there:
///    - the target app is frontmost right now → send it Esc (its popover is key, so Esc works); still there after
///      `escapeWait` → 3;
///    - not frontmost → click the item again **directly**: an inactive app's popover isn't key and Esc is ignored
///      (measured in the VM); sending Esc first would only delay the close by about 0.7–1 s.
/// 3. Click the item again (toggle it closed).
/// 4. Still there after `toggleWait` → stop waiting (the caller moves the icon back as usual).
///
/// No escalation while the presentation window is fading out (alpha < 1): it is already closing, and clicking the item
/// now would just reopen it. The 60 s cap (`nonMenuCap` of `ItemClicker.waitForPresentationToClose`) remains the last
/// resort.
public struct OutsideClickDismissal: Sendable {
    public enum Action: Equatable, Sendable {
        case none
        /// Send Esc (key down + key up) to the target app.
        case sendEscape
        /// Click the item's status icon again (HID click) to toggle the presentation closed.
        case clickItem
        /// Done everything possible, stop waiting: the caller ends the wait and moves the icon back.
        case giveUp
    }

    public struct Timing: Equatable, Sendable {
        /// How long to wait after an outside click before stepping in (when the target app isn't frontmost: it won't
        /// close by itself). Gives presentations that do close by themselves time to start fading out before the item
        /// is clicked (clicking the icon of a closing presentation reopens it).
        public var grace: Duration
        /// Grace period when the target app will handle this click itself (it is frontmost, or the click landed on
        /// another of its windows): the transient popover closes by itself and its window leaves the screen after
        /// about 0.5 s; only step in if it is still there after this.
        public var ownerHandlesGrace: Duration
        /// How long to wait after sending Esc before clicking the item. Must be longer than the time it takes the
        /// window to leave the screen after the popover closes (about 0.5 s); otherwise, if Esc already closed it and
        /// the window is still fading out, another click reopens it.
        public var escapeWait: Duration
        /// How long to wait after clicking the item before giving up.
        public var toggleWait: Duration

        public init(grace: Duration, ownerHandlesGrace: Duration, escapeWait: Duration, toggleWait: Duration) {
            self.grace = grace
            self.ownerHandlesGrace = ownerHandlesGrace
            self.escapeWait = escapeWait
            self.toggleWait = toggleWait
        }

        public static let standard = Timing(grace: .milliseconds(300), ownerHandlesGrace: .seconds(1),
                                            escapeWait: .milliseconds(700), toggleWait: .seconds(1))
    }

    public enum Phase: Equatable, Sendable {
        /// Waiting for an outside click.
        case idle
        /// Outside click detected, within the grace period.
        case outsideClick(at: ContinuousClock.Instant, grace: Duration)
        /// Esc sent.
        case escapeSent(at: ContinuousClock.Instant)
        /// The item has been clicked again.
        case itemClicked(at: ContinuousClock.Instant)
        /// Gave up.
        case finished
    }

    public let timing: Timing
    public private(set) var phase: Phase = .idle

    public init(timing: Timing = .standard) {
        self.timing = timing
    }

    /// Scope: third-party items with a known owner. With an unknown owner only menus can be detected (there's no
    /// non-menu presentation to handle); Apple system items (Control Center modules, Spotlight, etc.) handle outside
    /// clicks themselves and are left alone.
    public static func applies(ownerPID: pid_t?, bundleID: String?) -> Bool {
        ownerPID != nil && !ActivationHandOffPolicy.isSystemItem(bundleID: bundleID)
    }

    /// Whether a click position (CG global coordinates, top-left origin) is outside the presentation: not inside any
    /// presentation window, nor inside the item's status window (clicking the item itself is the user toggling it
    /// closed, which the app handles).
    public static func isOutside(_ point: CGPoint, presentationFrames: [CGRect], itemFrame: CGRect?) -> Bool {
        if let itemFrame, itemFrame.contains(point) { return false }
        return !presentationFrames.contains { $0.contains(point) }
    }

    /// AppKit global coordinates (bottom-left origin) → CG global coordinates (top-left origin):
    /// `y = primary display frame.maxY − y`.
    public static func cgPoint(fromAppKit point: CGPoint, primaryScreenMaxY: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenMaxY - point.y)
    }

    /// Records a mouse down (any button).
    /// - Parameters:
    ///   - point: CG global coordinates.
    ///   - presentationFrames: the app's presentation windows right now (including child windows opened later).
    ///   - itemFrame: the item's status window.
    ///   - ownerWindowFrames: the app's other on-screen windows: a real click on one of them activates the app, and the
    ///     transient popover closes by itself.
    ///   - ownerIsActive: whether the target app is frontmost now (or at the latest sample before the click).
    public mutating func mouseDown(at point: CGPoint, time: ContinuousClock.Instant, presentationFrames: [CGRect],
                                   itemFrame: CGRect?, ownerWindowFrames: [CGRect], ownerIsActive: Bool) {
        let outside = Self.isOutside(point, presentationFrames: presentationFrames, itemFrame: itemFrame)
        switch phase {
        case .idle:
            guard outside else { return }
            let ownerHandles = ownerIsActive || ownerWindowFrames.contains { $0.contains(point) }
            phase = .outsideClick(at: time, grace: ownerHandles ? timing.ownerHandlesGrace : timing.grace)
        case .outsideClick:
            // The user clicked back into the presentation (or the item) within the grace period: still using it,
            // cancel. Another outside click doesn't extend the grace period.
            if !outside { phase = .idle }
        case .escapeSent, .itemClicked, .finished:
            // Already closing it: no further change.
            break
        }
    }

    /// Called on every poll (only while the presentation is still on screen). `isFading`: the presentation window is
    /// fading out (alpha < 1), i.e. it is already closing. `ownerIsActive`: the target app is frontmost right now
    /// (decides whether to send Esc first or click the item again directly once the grace period is over).
    public mutating func poll(now: ContinuousClock.Instant, isFading: Bool, ownerIsActive: Bool) -> Action {
        switch phase {
        case .idle, .finished:
            return .none
        case let .outsideClick(at, grace):
            guard now - at >= grace, !isFading else { return .none }
            guard ownerIsActive else {
                phase = .itemClicked(at: now)
                return .clickItem
            }
            phase = .escapeSent(at: now)
            return .sendEscape
        case let .escapeSent(at):
            guard now - at >= timing.escapeWait, !isFading else { return .none }
            phase = .itemClicked(at: now)
            return .clickItem
        case let .itemClicked(at):
            // Fading out: the toggle click took effect; wait for it to disappear (it will be detected as closed).
            guard now - at >= timing.toggleWait, !isFading else { return .none }
            phase = .finished
            return .giveUp
        }
    }
}
