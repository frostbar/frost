import CoreGraphics

/// Geometry of the Frost Bar panel (AppKit coordinates: bottom-left origin, used only to place the NSWindow).
///
/// The panel drops down below the Frost icon (like a pull-down menu). The window has a transparent margin of
/// `inset` on every side (needed for the shadow), with the visible content (the rounded glass panel) inside it:
/// - maximum visible content width = `visibleFrame.width − 2 × margin`;
/// - the visible content's right edge aligns with the anchor's (the Frost icon's) right edge, staying at least
///   `margin` from `visibleFrame` on both sides;
/// - the visible content's top edge is `gap` below the menu bar's bottom edge, and it extends down to at most
///   `margin` above `visibleFrame`'s bottom edge.
/// When the content grows (e.g. holding ⌥ adds the always-hidden section) the top and right edges stay put and it
/// grows downward and leftward.
public enum PanelPlacement {
    public static let defaultGap: CGFloat = 6
    public static let defaultMargin: CGFloat = 8

    /// Maximum width of the visible content.
    public static func maxContentWidth(visibleFrame: CGRect, margin: CGFloat = defaultMargin) -> CGFloat {
        max(0, visibleFrame.width - 2 * margin)
    }

    /// Maximum height of the visible content: from `gap` below the menu bar to `margin` above `visibleFrame`'s
    /// bottom edge (beyond that the view scrolls vertically).
    public static func maxContentHeight(screenFrame: CGRect, visibleFrame: CGRect, menuBarHeight: CGFloat,
                                        gap: CGFloat = defaultGap, margin: CGFloat = defaultMargin) -> CGFloat {
        max(0, screenFrame.maxY - menuBarHeight - gap - (visibleFrame.minY + margin))
    }

    /// The screen's real menu bar height: `frame.maxY − visibleFrame.maxY` (39 on a notched display; don't use the
    /// 22 from `NSStatusBar.thickness`). With an auto-hiding menu bar, visibleFrame doesn't exclude the menu bar
    /// (the result is 0), so `fallback` (the height of the Frost icon window) is used instead.
    public static func menuBarHeight(screenFrame: CGRect, visibleFrame: CGRect, fallback: CGFloat) -> CGFloat {
        let height = screenFrame.maxY - visibleFrame.maxY
        return height > 0 ? height : fallback
    }

    /// The panel window's frame. `size` is the window size (including margins); if the visible content is wider
    /// than the available width, it starts at the left margin. `topInset` is the transparent margin above the
    /// visible content (defaults to `inset`). With `topInset == gap` the window's top edge sits exactly on the menu
    /// bar's bottom edge, so the panel's shadow is not drawn into the menu bar (on real hardware that shows as a
    /// dark band that flickers when the freeze frame is put up / removed).
    public static func frame(size: CGSize, inset: CGFloat, topInset: CGFloat? = nil, anchorMaxX: CGFloat,
                             screenFrame: CGRect, visibleFrame: CGRect, menuBarHeight: CGFloat,
                             gap: CGFloat = defaultGap, margin: CGFloat = defaultMargin) -> CGRect {
        let topInset = topInset ?? inset
        let contentWidth = max(0, size.width - 2 * inset)
        let minX = visibleFrame.minX + margin
        let maxX = visibleFrame.maxX - margin - contentWidth
        let contentX = maxX < minX ? minX : min(max(anchorMaxX - contentWidth, minX), maxX)
        let contentTop = screenFrame.maxY - menuBarHeight - gap
        return CGRect(x: contentX - inset, y: contentTop + topInset - size.height, width: size.width, height: size.height)
    }
}
