import CoreGraphics

/// Records which items still can't be captured after a temporary expand, deciding whether it's worth temporarily
/// expanding the menu bar for them in Frost Bar.
///
/// Hidden items that are pushed out can only be captured after a temporary expand. On a crowded notched display,
/// items that don't fit after expanding are tucked under the notch (`isOnScreen == false`) and can never be captured.
/// Rules:
///
/// - Items still off screen after a temporary expand are "blocked" (the disk-cached capture or the app icon is shown);
/// - until the layout (the set of menu bar items or their left-to-right order) or the display configuration changes:
///   they might fit then, so all blocks are lifted.
///
/// Live refresh while Frost Bar is open (`LiveRefreshPolicy`) expands all items every cycle, and blocked items don't
/// affect its cadence; it stops expanding only when **all** items in the panel are blocked
/// (`Conditions.hasCapturableItems`), avoiding an expand every second that captures nothing.
///
/// The context must be computed in the same section state (always collapsed while Frost Bar is open); positions
/// before and after expanding are not comparable.
public struct CaptureRetryPolicy: Sendable {
    /// Context for deciding "whether the situation changed": the left-to-right order of menu bar items (including
    /// Frost's separators, so it also reflects sections) and the display configuration.
    public struct Context: Equatable, Sendable {
        public var itemOrder: [CGWindowID]
        public var displays: [Display]

        public init(itemOrder: [CGWindowID], displays: [Display]) {
            self.itemOrder = itemOrder
            self.displays = displays
        }

        /// Orders `items` left to right by x (by windowID when x is equal); width changes (e.g. the clock, text items)
        /// don't count as layout changes.
        public init(items: [MenuBarItem], displays: [Display]) {
            let sorted = items.sorted { ($0.frame.minX, $0.windowID) < ($1.frame.minX, $1.windowID) }
            self.init(itemOrder: sorted.map(\.windowID), displays: displays)
        }
    }

    /// One display's configuration: ID, global frame (points), and scale.
    public struct Display: Equatable, Sendable {
        public var id: CGDirectDisplayID
        public var frame: CGRect
        public var scale: CGFloat

        public init(id: CGDirectDisplayID, frame: CGRect, scale: CGFloat) {
            self.id = id
            self.frame = frame
            self.scale = scale
        }
    }

    public private(set) var blocked: Set<CGWindowID> = []
    private var blockedContext: Context?

    public init() {}

    /// Items in `missing` (items lacking a capture, order preserved) worth a temporary expand. If the context differs
    /// from the one at blocking time, all blocks are lifted first.
    public mutating func expandable(_ missing: [CGWindowID], in context: Context) -> [CGWindowID] {
        if blockedContext != context {
            blocked = []
            blockedContext = nil
        }
        return missing.filter { !blocked.contains($0) }
    }

    /// Called after a temporary expand finishes: items in `attempted` that are in `stillMissing` are not retried while
    /// the context `context` (from before the expand) is unchanged. If the context differs from the previous blocking
    /// context, the existing blocks are replaced.
    public mutating func recordAttempt(_ attempted: [CGWindowID], stillMissing: Set<CGWindowID>, in context: Context) {
        if blockedContext != context { blocked = [] }
        blockedContext = context
        for id in attempted {
            if stillMissing.contains(id) { blocked.insert(id) } else { blocked.remove(id) }
        }
    }

    /// Lifts all blocks (when the user refreshes manually).
    public mutating func reset() {
        blocked = []
        blockedContext = nil
    }
}
