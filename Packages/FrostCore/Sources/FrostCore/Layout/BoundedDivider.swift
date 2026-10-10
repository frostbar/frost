import CoreGraphics

/// How wide Frost's own dividers are on macOS 27, where hiding works differently from macOS 26.
///
/// On 26 a separator set to `length = 10_000` is clamped by the system to a 5016 pt window, which pushes every item
/// on its left off screen — a hard boundary. On 27 that separator is dropped from the bar and comes back reordered,
/// so Frost uses `NSStatusItem`s of a **bounded** width instead: the trailing area is right-aligned, a wide own item
/// consumes its width there, and the items that no longer fit leave the bar (the system may offer an
/// overflow chevron).
///
/// Each boundary uses a pair, placed together immediately after its configured section. A single wide item at
/// the far left merely consumes capacity and can leave configured Hidden icons visible. Pair requests stay below
/// the per-item width limit; requested widths and negative AX hits never certify physical absence.
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

    /// The measured narrow slot on 27. Do not apply the 26 window-constraint trick: it makes AppKit's frame
    /// disagree with the item actually hit in the menu bar.
    public static let revealWidth: CGFloat = 8

    /// The thin vertical line the layout editor shows for a divider (`length = 8`), as on macOS 26.
    public static let editingWidth: CGFloat = 8

    public static let absoluteCap: CGFloat = 600
    static let margin: CGFloat = 32
    public static let minimumUsefulWidth: CGFloat = 200

    /// Whether a divider of `width` is expected to leave the bar as it is (nothing hidden). Used to keep the
    /// language honest: a collapse the system ignores must not be reported as "hidden".
    public static func isEffective(width: CGFloat, displayWidth: CGFloat) -> Bool {
        width >= minimumUsefulWidth && width < displayWidth / 2
    }
}
