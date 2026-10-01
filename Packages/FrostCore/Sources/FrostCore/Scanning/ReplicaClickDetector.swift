import CoreGraphics
import Foundation

/// Multiple displays: detects clicks that land on the snowflake replica on an inactive display but never reach
/// the Frost icon button, so that Frost can deliver the click itself.
///
/// Background (`MenuBarDisplayResolver`): the real window of the Frost icon is only on the display with the
/// active menu bar; other displays show replicas. Clicking a replica makes the system first move the active menu
/// bar to that display (the real window and the replica swap places), and this mouse down / up first shows up in
/// Frost's **global** monitor as "another app's event". In the VM (a virtual display inside the guest) the system
/// then redelivers the down and up to the real window that just moved over (the local monitor sees a down with the
/// same timestamp about 35 ms later and the button fires its action as usual); on real hardware (built-in display
/// + external display) the first click on Frost does nothing and only the second one works (in both directions):
/// the click is never delivered to the button.
///
/// Rules (a pure state machine; all times are event timestamps / `systemUptime`, in seconds):
/// 1. A down seen by the global monitor inside some display's snowflake replica (`replicaIcons`, slightly
///    enlarged) → record a pending click.
/// 2. Up (global or local monitor) → record the up time; if the click is not delivered within `grace`,
///    synthesize it once (`due`). No up within `maxHold` after the down (press-and-hold / drag) → give up.
/// 3. Delivered: the local monitor sees a down with the same timestamp on the Frost icon window
///    (`deliveredMouseDown`), or the button fires its action (`actionReceived`) → cancel the pending click and let
///    the button handle it as usual.
/// 4. After a synthesized click, the button fires a late action (event timestamp no later than the synthesized
///    click's up) → `actionReceived` returns false and the action is ignored, so it does not toggle twice.
public struct ReplicaClickDetector: Sendable {
    public enum Button: Equatable, Sendable {
        case left, right
    }

    /// A click that Frost needs to deliver itself.
    public struct Click: Equatable, Sendable {
        public var displayID: CGDirectDisplayID
        public var button: Button
        public var control: Bool
        public var option: Bool

        public init(displayID: CGDirectDisplayID, button: Button, control: Bool, option: Bool) {
            self.displayID = displayID
            self.button = button
            self.control = control
            self.option = option
        }

        /// Right click or ctrl-left click: show the menu.
        public var isContextClick: Bool { button == .right || control }
    }

    struct Pending: Equatable, Sendable {
        var click: Click
        var downTime: TimeInterval
        var upTime: TimeInterval?
    }

    /// How long after the up to wait for delivery before synthesizing the click (VM redelivery takes ~35 ms).
    public static let grace: TimeInterval = 0.3
    /// Maximum time to wait for the up after the down.
    public static let maxHold: TimeInterval = 2
    /// Amount each replica frame edge is enlarged by (replica frames come from the previous scan).
    public static let slop: CGFloat = 1
    /// The same event has exactly the same timestamp in the global and local monitors; allow a little float slack.
    static let sameEventTolerance: TimeInterval = 0.001

    private(set) var pending: Pending?
    /// Up time of the most recently synthesized click: later button actions for that same click are ignored.
    private var lastSynthesizedUpTime: TimeInterval?

    public init() {}

    /// Whether a click is pending (for diagnostics / tests).
    public var hasPendingClick: Bool { pending != nil }

    /// The global monitor saw a mouse down (CG coordinates). Returns true if it hit a replica.
    @discardableResult
    public mutating func globalMouseDown(at point: CGPoint, time: TimeInterval, button: Button, control: Bool,
                                         option: Bool, replicaIcons: [CGDirectDisplayID: CGRect]) -> Bool {
        let hit = replicaIcons
            .sorted { $0.key < $1.key }
            .first { $0.value.insetBy(dx: -Self.slop, dy: -Self.slop).contains(point) }
        guard let hit else {
            pending = nil
            return false
        }
        pending = Pending(click: Click(displayID: hit.key, button: button, control: control, option: option),
                          downTime: time, upTime: nil)
        return true
    }

    /// Mouse up (global or local monitor).
    public mutating func mouseUp(button: Button, time: TimeInterval) {
        guard var current = pending, current.click.button == button, current.upTime == nil, time >= current.downTime
        else { return }
        current.upTime = time
        pending = current
    }

    /// The local monitor saw a mouse down on the Frost icon window: the same timestamp as the pending click means
    /// the system delivered it, and the button will handle it as usual.
    public mutating func deliveredMouseDown(time: TimeInterval) {
        guard let current = pending, abs(current.downTime - time) <= Self.sameEventTolerance else { return }
        pending = nil
    }

    /// The button fired its action (`eventTime` is the timestamp of the triggering event). Returns false if this is
    /// the click that was already synthesized; the caller should ignore it.
    public mutating func actionReceived(eventTime: TimeInterval) -> Bool {
        if let upTime = lastSynthesizedUpTime, eventTime <= upTime + Self.sameEventTolerance {
            return false
        }
        pending = nil
        return true
    }

    /// Due check: returns the click to synthesize, if any (and clears the pending state).
    public mutating func due(now: TimeInterval) -> Click? {
        guard let current = pending else { return nil }
        guard let upTime = current.upTime else {
            if now >= current.downTime + Self.maxHold { pending = nil }
            return nil
        }
        guard now >= upTime + Self.grace else { return nil }
        pending = nil
        lastSynthesizedUpTime = upTime
        return current.click
    }
}
