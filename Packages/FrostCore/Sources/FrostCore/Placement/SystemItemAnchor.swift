import CoreGraphics

/// The item Frost's snowflake belongs immediately left of: the leftmost member of the run of system items at the
/// **trailing** (right) end of the menu bar.
///
/// Not simply "the leftmost item Frost can't move". On macOS 27 the bar's own process owns the overflow chevron as
/// well as the clock and the Control Center button, and the chevron sits at the *left* end of the trailing area, so
/// the leftmost immovable item is the chevron whenever the bar overflows — the snowflake would then be placed behind
/// it, at the far left, instead of next to Control Center, and a crowded bar is exactly when it must not. The chevron
/// is recognized by describing itself (`SystemItemRules.isOverflowChevron`) and skipped.
public enum SystemItemAnchor {
    /// - Parameters:
    ///   - items: everything the bar reports, Frost's own items included (they sit in the middle of the trailing
    ///     area and are not anchors).
    ///   - own: the window IDs of Frost's own items.
    ///   - displayBounds: the managed menu bar's display. Frames are global CG coordinates, so an item on a display
    ///     placed left of the primary one has a negative x and is perfectly valid — what matters is that the item is
    ///     on this display.
    public static func trailingAnchor(among items: [MenuBarItem], own: Set<CGWindowID>,
                                      displayBounds: CGRect) -> MenuBarItem? {
        let candidates = items
            .filter { !own.contains($0.windowID) && $0.frame.width > 0
                && $0.frame.maxX > displayBounds.minX && $0.frame.minX < displayBounds.maxX }
            .sorted { ($0.frame.minX, $0.windowID) < ($1.frame.minX, $1.windowID) }
        var anchor: MenuBarItem?
        for item in candidates.reversed() {
            if SystemItemRules.isOverflowChevron(bundleID: item.bundleID, axDescription: item.axDescription) {
                continue
            }
            guard !item.isMovable else { break }
            anchor = item
        }
        return anchor
    }
}
