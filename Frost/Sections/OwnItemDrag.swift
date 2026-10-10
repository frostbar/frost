import AppKit
import FrostCore

/// A ⌘-drag of one of **Frost's own** status items, used on macOS 27 to put the snowflake and the dividers where
/// the macOS 26 layout has them.
///
/// macOS 27 gives a newly created status item the first free slot of the trailing area (`MenuBarAgent` decides the
/// order, and a saved 26 `NSStatusItem Preferred Position` no longer places anything). On a bar with a handful of
/// icons that slot is simply the leftmost one; on a busy bar it is already behind the system's overflow chevron, so
/// a first run without placement can leave the snowflake unreachable (`docs/macos-behavior.md`, "macOS 27").
///
/// Safety: the mouse-down lands on the center of Frost's own control item — the same rule the 26 mover follows
/// (never a synthesized ⌘ mouse-down at a third-party item's position). The pointer is hidden for the duration and
/// put back afterwards, and the drag runs inside `ItemMover.transaction` like every other move.
enum OwnItemDrag {
    struct Result: Sendable {
        /// Whether the mouse-down was posted at all (false when the user's mouse was busy).
        let posted: Bool
        /// Where the pointer ended up, for the log.
        let endX: CGFloat
    }

    /// Target x tolerance when checking whether an item is already where it should be (pt).
    static let tolerance: CGFloat = 24

    /// Posts the drag on a background thread (it sleeps between events, and the main thread has to stay free to
    /// handle them). Returns nil when a mouse button was held right before the mouse-down, so nothing was posted.
    nonisolated static func post(itemCenter: CGPoint, toX: CGFloat, steps: Int = 24) -> Result? {
        guard !UserMouseButtons.isAnyHeld else { return nil }
        var result: Result?
        SyntheticEventGate.posting {
            result = postNow(itemCenter: itemCenter, toX: toX, steps: steps)
        }
        return result
    }

    private nonisolated static func postNow(itemCenter: CGPoint, toX: CGFloat, steps: Int) -> Result {
        let source = CGEventSource(stateID: .hidSystemState)
        // The user's own input wins: if they press a mouse button while Frost is placing its own items, the drag ends
        // at once (the mouse-up is still posted, so nothing is left held) instead of carrying their click along for
        // the rest of the gesture. The same rule `ItemMover.moveDirect` follows.
        let presses = UserMouseButtons.pressCount
        let saved = CGEvent(source: nil)?.location
        let concealment = CursorConcealment.begin()
        defer { concealment.end(warpingTo: saved) }

        func post(_ type: CGEventType, _ point: CGPoint) -> Bool {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                      mouseButton: .left) else { return false }
            event.flags = .maskCommand
            event.post(tap: .cgSessionEventTap)
            return true
        }

        guard post(.mouseMoved, itemCenter), post(.leftMouseDown, itemCenter) else {
            return Result(posted: false, endX: itemCenter.x)
        }
        usleep(60_000)
        // The first dragged event is what lifts the item; without it the system treats the sequence as a click.
        _ = post(.leftMouseDragged, CGPoint(x: itemCenter.x + 2, y: itemCenter.y))
        for step in 1...max(1, steps) {
            if UserMouseButtons.isAnyHeld || UserMouseButtons.pressCount != presses { break }
            let t = CGFloat(step) / CGFloat(max(1, steps))
            _ = post(.leftMouseDragged, CGPoint(x: itemCenter.x + (toX - itemCenter.x) * t, y: itemCenter.y))
            usleep(12_000)
        }
        usleep(80_000)
        let ended = CGEvent(source: nil)?.location ?? CGPoint(x: toX, y: itemCenter.y)
        _ = post(.leftMouseUp, ended)
        usleep(40_000)
        return Result(posted: true, endX: toX)
    }
}
