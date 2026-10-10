import CoreGraphics

/// Recognizes the status items macOS doesn't let anyone move: Control Center's clock and Control Center button, which
/// always sit at the trailing end of the menu bar (Control Center, then the clock).
///
/// Evidence, strongest first (measured on macOS 26):
/// 1. The AX identifier: `com.apple.menuextra.clock` / `com.apple.menuextra.controlcenter` (needs only
///    Accessibility; other Control Center modules have their own identifiers and are movable).
/// 2. The window title: `Clock` / `BentoBox…` (needs Screen Recording).
/// 3. Neither known (no Screen Recording and the owner unresolved, or no identifier): the two trailing windows of the
///    menu bar (`trailingSlots`), decided conservatively.
///
/// Items of any other owner are always movable (a third-party "Clock" is just a clock).
public enum SystemItemRules {
    public static let controlCenterBundleID = "com.apple.controlcenter"
    public static let clockIdentifier = "com.apple.menuextra.clock"
    public static let controlCenterIdentifier = "com.apple.menuextra.controlcenter"
    /// On macOS 27 `MenuBarAgent` draws the whole bar and reports the extras it owns itself: the clock, the Control
    /// Center button and the overflow chevron, none of which can be moved or hidden by anyone else.
    public static let menuBarAgentBundleID = "com.apple.MenuBarAgent"
    static let fixedIdentifiers: Set<String> = [clockIdentifier, controlCenterIdentifier]

    /// Whether an item with these attributes is fixed by the system. `bundleID == nil` means the owner is unresolved:
    /// it might be Control Center.
    public static func isFixed(bundleID: String?, axIdentifier: String?, windowTitle: String,
                               occupiesSystemSlot: Bool) -> Bool {
        guard bundleID == controlCenterBundleID || bundleID == menuBarAgentBundleID || bundleID == nil
        else { return false }
        // Everything the bar's own process owns is fixed: on 27 that is the clock, the Control Center button and the
        // overflow chevron. They never describe themselves the way Control Center's items do on 26, so the checks
        // below can't tell them apart — the owner itself does.
        if bundleID == menuBarAgentBundleID { return true }
        if let axIdentifier, !axIdentifier.isEmpty { return fixedIdentifiers.contains(axIdentifier) }
        if !windowTitle.isEmpty { return windowTitle == "Clock" || windowTitle.hasPrefix("BentoBox") }
        return occupiesSystemSlot
    }

    /// Whether the item is macOS 27's overflow chevron.
    ///
    /// The bar's own process owns it, and — unlike the clock and the Control Center button, which have neither an
    /// identifier, a description nor a title — it describes itself ("Show Hidden Menu Bar Items"). That is what tells
    /// the three apart: the chevron sits at the *left* end of the trailing area, so treating it as one of the
    /// trailing system items would put Frost's snowflake at the far left instead of next to Control Center.
    public static func isOverflowChevron(bundleID: String?, axDescription: String?) -> Bool {
        bundleID == menuBarAgentBundleID && !(axDescription ?? "").isEmpty
    }

    /// The window IDs of the two trailing on-screen windows of the managed menu bar (largest right edge), excluding
    /// `excluded` (Frost's own windows): where the Control Center button and the clock always are. Pushed-out windows
    /// are off screen and never qualify.
    public static func trailingSlots(_ windows: [RawStatusWindow], excluding excluded: Set<CGWindowID> = [])
        -> Set<CGWindowID> {
        let candidates = windows.filter { $0.isOnScreen && $0.frame.width > 0 && !excluded.contains($0.windowID) }
        return Set(candidates.sorted { $0.frame.maxX > $1.frame.maxX }.prefix(2).map(\.windowID))
    }
}
