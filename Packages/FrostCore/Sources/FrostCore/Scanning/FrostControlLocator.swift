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
    public static func locate(in items: [MenuBarItem], iconFrame: CGRect?, hiddenFrame: CGRect?,
                              alwaysHiddenFrame: CGRect?) -> FrostControlWindows? {
        guard let icon = find(in: items, frame: iconFrame, title: iconTitle),
              let hidden = find(in: items, frame: hiddenFrame, title: hiddenSeparatorTitle),
              let alwaysHidden = find(in: items, frame: alwaysHiddenFrame, title: alwaysHiddenSeparatorTitle)
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
