import CoreGraphics

/// Decides when the mouse-up of a synthetic ⌘-drag may be posted, and where (`ItemMover.postCommandDrag`).
///
/// Measured in the VM (macOS 26.6.2): the mouse-down lifts the dragged item out of the menu bar — its window jumps to
/// the cursor (about 20 ms after the event) — and the system reserves a slot for it **at the mouse-down position**
/// (next to the Frost icon, where the mouse-down physically lands). The items between the item's old slot and that
/// slot slide over to close the gap (an animation of about 0.4 s while on screen; in the collapsed state the Frost
/// icon itself slides). The mouse-up is then placed against those *current* positions. So a mouse-up aimed at
/// frames read before the drag:
/// - is ignored when it arrives before the lift (the item doesn't move at all: about one move in four with a 50 ms
///   down → up interval, none at 200 ms);
/// - lands one slot off when the target is one of the items sliding over (e.g. moving an item rightwards within the
///   Hidden section, or from Always Hidden into Hidden: it ended up right of the target instead of left of it).
///
/// So the mouse-up is posted only once the item has been lifted, aimed at the target's frame at that moment; when the
/// target may be one of the sliding windows (`targetMaySlide`), only once every other window has stopped moving.
public struct DragRelease: Sendable {
    public let itemID: CGWindowID
    public let destination: MoveDestination
    /// The dragged item's frame before the mouse-down.
    public let originalFrame: CGRect
    /// Whether the target may slide while the item is lifted (see `targetMaySlide(...)`): then the mouse-up waits until
    /// the menu bar has stopped moving.
    public let waitsForStillness: Bool
    /// Snapshots required after the lift, and (when `waitsForStillness`) consecutive snapshots without any change.
    public var requiredSnapshots: Int

    public private(set) var isLifted = false
    private var snapshotsSinceLift = 0
    private var previous: [CGWindowID: CGRect]?
    private var unchanged = 0

    public init(itemID: CGWindowID, destination: MoveDestination, originalFrame: CGRect, waitsForStillness: Bool,
                requiredSnapshots: Int = 3) {
        self.itemID = itemID
        self.destination = destination
        self.originalFrame = originalFrame
        self.waitsForStillness = waitsForStillness
        self.requiredSnapshots = requiredSnapshots
    }

    /// Feeds one snapshot of the menu bar's windows (polled while the mouse button is down); returns true once the
    /// mouse-up may be posted: the item has left its original frame (lifted) at least `requiredSnapshots` snapshots ago
    /// and, when `waitsForStillness`, no other window has moved for `requiredSnapshots` snapshots in a row.
    public mutating func observe(_ frames: [CGWindowID: CGRect]) -> Bool {
        if !isLifted, let frame = frames[itemID], frame != originalFrame { isLifted = true }
        if isLifted { snapshotsSinceLift += 1 }
        var others = frames
        others[itemID] = nil
        unchanged = others == previous ? unchanged + 1 : 0
        previous = others
        guard isLifted, snapshotsSinceLift >= requiredSnapshots else { return false }
        return !waitsForStillness || unchanged + 1 >= requiredSnapshots
    }

    /// The mouse-up position against `frames` (the latest snapshot); nil if the target is missing from it.
    public func dropPoint(in frames: [CGWindowID: CGRect]) -> CGPoint? {
        guard let target = frames[destination.targetWindowID] else { return nil }
        return ItemMover.dropPoint(for: destination, targetFrame: target)
    }

    /// Whether the target may slide while the item is lifted, so that a mouse-up aimed at its frame before the drag
    /// could land in another slot. The windows that slide lie between the item's old slot and the mouse-down (the Frost
    /// icon, which itself slid in the collapsed state but not while editing). Not the case for a target beyond the icon
    /// or beyond the item, nor for `rightOf(icon)` with the item left of the icon (the Frost Bar moving an icon out): the
    /// gap right of the icon stays under that point whether or not the icon slides.
    public static func targetMaySlide(itemFrame: CGRect, destination: MoveDestination, targetFrame: CGRect,
                                      iconID: CGWindowID, iconFrame: CGRect) -> Bool {
        if destination.targetWindowID == iconID {
            if case .rightOf = destination, itemFrame.minX < iconFrame.minX { return false }
            return true
        }
        let low = min(itemFrame.minX, iconFrame.minX), high = max(itemFrame.minX, iconFrame.minX)
        return targetFrame.minX > low && targetFrame.minX < high
    }
}
