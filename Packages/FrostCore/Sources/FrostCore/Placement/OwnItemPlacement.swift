import CoreGraphics

/// Whether one of Frost's own status items has been placed where it belongs: against its anchor, on the right side.
///
/// The check is adjacency, not order. A strict "next in the sorted order" comparison is wrong here twice over: the
/// system leaves a blank gap of up to about 14 pt between adjacent status items (measured on macOS 27: frames 1148
/// and 1172 for 10 pt wide dividers), and while an item is being dragged into place the two are often within a point
/// of each other, which makes their order a coin flip. Both made a placement that had really worked look like a
/// failure — and a false verdict is exactly what a "did it work?" retry acts on.
public enum OwnItemPlacement {
    /// Where the item belongs relative to its anchor.
    public enum Side: Sendable {
        /// Immediately to the anchor's right.
        case right
        /// Immediately to the anchor's left.
        case left
    }

    /// How far apart the two may end up and still count as next to each other (pt).
    public static let tolerance: CGFloat = 24

    public static func isSatisfied(item: CGRect, anchor: CGRect, side: Side,
                                   tolerance: CGFloat = tolerance) -> Bool {
        // Two conditions, and both are needed: the item has to be on the wanted side at all (`midX`, which the
        // widths can't confuse), and the gap between the facing edges has to be within the tolerance — a *one-sided*
        // bound, since a tolerance wide enough to cover the system's blank gap is also wider than a divider, and
        // `abs` would then accept an item that sits just as close on the wrong side.
        let gap = switch side {
        case .right: item.minX - anchor.maxX
        case .left: anchor.minX - item.maxX
        }
        guard gap <= tolerance else { return false }
        return switch side {
        case .right: item.midX > anchor.midX
        case .left: item.midX < anchor.midX
        }
    }
}
