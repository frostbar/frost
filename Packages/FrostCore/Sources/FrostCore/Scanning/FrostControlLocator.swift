import CoreGraphics

/// Locates Frost's own three control items in the scan results.
///
/// `button.window.windowNumber` is not a CG windowID (it is `k << 32`; converting it overflows and crashes), so
/// items are matched by frame: the app layer converts `button.window.frame` from AppKit to CG coordinates
/// (`y = primaryScreenMaxY - frame.maxY`) and passes it in. If no frame matches, falls back to window title ==
/// autosaveName, an optional extra: titles are empty without Screen Recording, and the frame match needs none.
public enum FrostControlLocator {
    public static let iconTitle = "FrostIcon"
    public static let hiddenSeparatorTitle = "FrostHiddenSeparator"
    public static let alwaysHiddenSeparatorTitle = "FrostAlwaysHiddenSeparator"

    /// Frame match tolerance: midX and width both within ±2 pt.
    public static let tolerance: CGFloat = 2

    /// Returns a result when all three are found; nil if any has neither a frame match nor a title match.
    ///
    /// `titles` are the autosave names the items were created with. macOS 27 uses its own names
    /// (`SectionController.accessibilityHiddenAutosaveName` and its neighbours), and the frame fallback is weaker
    /// there — a divider held as a thin line reports an Accessibility frame that differs from its window's — so the
    /// names have to be the ones in use, or Frost's own items end up looking like ordinary menu bar icons.
    public static func locate(in items: [MenuBarItem], iconFrame: CGRect?, hiddenFrame: CGRect?,
                              alwaysHiddenFrame: CGRect?,
                              titles: (icon: String, hidden: String, alwaysHidden: String)
                                  = (iconTitle, hiddenSeparatorTitle, alwaysHiddenSeparatorTitle))
        -> FrostControlWindows? {
        guard let icon = find(in: items, frame: iconFrame, title: titles.icon),
              let hidden = find(in: items, frame: hiddenFrame, title: titles.hidden),
              let alwaysHidden = find(in: items, frame: alwaysHiddenFrame, title: titles.alwaysHidden)
        else { return nil }
        return FrostControlWindows(icon: icon, hiddenSeparator: hidden, alwaysHiddenSeparator: alwaysHidden)
    }

    /// With multiple candidates (e.g. after a relaunch, a leftover window from the previous instance has the same
    /// frame / title as the new one), prefers on-screen windows, then the larger (newer) windowID.
    static func find(in items: [MenuBarItem], frame: CGRect?, title: String) -> CGWindowID? {
        if let frame, let hit = preferred(items.filter {
            abs($0.frame.midX - frame.midX) <= tolerance && abs($0.frame.width - frame.width) <= tolerance
        }) {
            return hit.windowID
        }
        return preferred(items.filter { $0.windowTitle == title })?.windowID
    }

    private static func preferred(_ candidates: [MenuBarItem]) -> MenuBarItem? {
        candidates.max { a, b in (a.isOnScreen ? 1 : 0, a.windowID) < (b.isOnScreen ? 1 : 0, b.windowID) }
    }
}
