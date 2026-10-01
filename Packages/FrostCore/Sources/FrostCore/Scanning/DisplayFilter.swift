import CoreGraphics

/// For which display a status bar window itself belongs to, see `MenuBarDisplayResolver`.
public enum DisplayFilter {
    /// Keeps the AX items describing the menu bar of `display` (the display with the active menu bar): center y
    /// within its menu bar row, any x.
    ///
    /// AX frames are the frames of the real windows (`button.window`), which are always on the display with the
    /// active menu bar (measured with multiple displays, see `MenuBarDisplayResolver`) — the same set of windows as
    /// the scan results. Pushed-out items have a negative x and may even fall within another display's horizontal
    /// range (when a secondary display is on the left); they must all be kept, or they would never get ownership.
    /// Items are dropped when the active menu bar moved to another display during the read (a different row with
    /// vertically stacked displays); the same race within one row is ruled out by `AXItemMatcher.consensusOwnership`,
    /// which requires the CG snapshots before and after the read to agree.
    public static func axItems(_ items: [AXItemInfo], onMenuBarOf display: MenuBarDisplay) -> [AXItemInfo] {
        let height = display.menuBarHeight > 0 ? display.menuBarHeight : fallbackMenuBarHeight
        let row = (display.frame.minY - 1)...(display.frame.minY + height + 1)
        return items.filter { row.contains($0.frame.midY) }
    }

    /// Upper bound for the row height when the menu bar auto-hides (height unknown).
    static let fallbackMenuBarHeight: CGFloat = 60
}
