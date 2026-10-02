import CoreGraphics

/// Decides when an item moved by a ⌘-drag has reached its final frame, so the Frost Bar can click it right away instead
/// of waiting for the whole menu bar to stop moving (`ItemMover.move(_:to:until:)` with `.itemLanded`).
///
/// Measured in the VM (macOS 26.6.2): on the mouse-up the dragged item jumps from the cursor straight into its new slot
/// (within a few ms, sometimes through one intermediate frame); it doesn't slide. What slides afterwards (~0.4 s) are
/// the windows *left* of the slot: the Frost icon and the separators make room for it. The menu bar is right-aligned,
/// so nothing right of the slot moves, and the item's final frame is predictable: in line with the menu bar row, its
/// right edge against the left edge of the next window on its right. A menu opened once the item is there is anchored
/// at the item's final position (it opens where the item's window is when clicked).
///
/// The item has landed when the order is right (`ItemMover.isSatisfied`), its frame is on the row of its right
/// neighbour and touches it (docked), and that frame was the same in `requiredStableSnapshots` snapshots in a row.
/// Without a right neighbour (no window to compare against) it never reports landed; the caller then falls back to
/// waiting for every window to stop moving.
public struct LandingDetector: Sendable {
    public let itemID: CGWindowID
    public let destination: MoveDestination
    public var requiredStableSnapshots: Int

    private var previous: CGRect?
    private var stable = 0

    public init(itemID: CGWindowID, destination: MoveDestination, requiredStableSnapshots: Int = 2) {
        self.itemID = itemID
        self.destination = destination
        self.requiredStableSnapshots = requiredStableSnapshots
    }

    /// Feeds one snapshot of the menu bar's windows; returns true once the item has landed (see the type's doc).
    public mutating func observe(_ frames: [CGWindowID: CGRect]) -> Bool {
        guard let frame = frames[itemID], ItemMover.isSatisfied(itemID, destination, frames: frames),
              Self.isDocked(itemID, frames: frames) else {
            previous = nil
            stable = 0
            return false
        }
        stable = frame == previous ? stable + 1 : 1
        previous = frame
        return stable >= requiredStableSnapshots
    }

    /// Whether the item sits in line with the next window on its right (by minX) and touches it (1 pt tolerance). False
    /// while it is lifted (it hangs at the cursor, below the row) or still overlapping a neighbour, and when there is no
    /// window on its right.
    static func isDocked(_ itemID: CGWindowID, frames: [CGWindowID: CGRect], tolerance: CGFloat = 1) -> Bool {
        guard let frame = frames[itemID] else { return false }
        let right = frames.filter { $0.key != itemID && $0.value.minX > frame.minX }
            .min { ($0.value.minX, $0.key) < ($1.value.minX, $1.key) }?.value
        guard let right else { return false }
        return abs(frame.minY - right.minY) <= tolerance && abs(frame.maxX - right.minX) <= tolerance
    }
}
