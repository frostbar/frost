import CoreGraphics

/// How wide Frost's own dividers are on macOS 27, where hiding works differently from macOS 26.
///
/// On 26 a separator set to `length = 10_000` is clamped by the system to a 5016 pt window, which pushes every item
/// on its left off screen — a hard boundary. On 27 that separator is dropped from the bar and comes back reordered,
/// so Frost uses `NSStatusItem`s of a **bounded** width instead: the trailing area is right-aligned, a wide own item
/// consumes its width there, and the items that no longer fit leave the bar (they end up behind the system's
/// overflow chevron).
///
/// Measured on macOS 27.0 (26A428), 1728 pt display, 15 third-party items (see `docs/macos-behavior.md`, "macOS 27"):
/// a divider's width is honoured up to just under half the display; with 300 pt five items left the bar, with 600 pt
/// seven, with 800 pt ten, and at 860 pt and above the width was *ignored* and nothing left. How many items leave is
/// therefore a function of the bar's contents, not of the divider's position: moving a divider does not move the
/// boundary, and Frost must never claim that a particular item is hidden. What it can promise is the direction —
/// wider means fewer icons drawn, narrower means more.
public enum BoundedDivider {
    /// The width a divider takes when its section is collapsed.
    ///
    /// `displayWidth / 2 - 32` is the measured limit with a safety margin (1728 pt display: 832 pt); the absolute cap
    /// keeps the request well inside the measured safe range on very wide displays. nil when the display is too
    /// narrow for a divider to consume a useful part of the bar — the caller then keeps the divider narrow and tells
    /// the user instead of pretending to hide something.
    public static func collapseWidth(displayWidth: CGFloat) -> CGFloat? {
        let width = min(absoluteCap, displayWidth / 2 - margin)
        return width >= minimumUsefulWidth ? width : nil
    }

    /// An invisible divider, so narrow that it consumes no visible space. `length = 0` still leaves a system gap of
    /// 16 pt on 26; on 27 the same is possible but harmless, and the app layer narrows the window the same way it
    /// does there.
    public static let revealWidth: CGFloat = 0

    /// The thin vertical line the layout editor shows for a divider (`length = 8`), as on macOS 26.
    public static let editingWidth: CGFloat = 8

    public static let absoluteCap: CGFloat = 832
    static let margin: CGFloat = 32
    public static let minimumUsefulWidth: CGFloat = 200

    /// Whether a divider of `width` is expected to leave the bar as it is (nothing hidden). Used to keep the
    /// language honest: a collapse the system ignores must not be reported as "hidden".
    public static func isEffective(width: CGFloat, displayWidth: CGFloat) -> Bool {
        width >= minimumUsefulWidth && width < displayWidth / 2
    }
}
