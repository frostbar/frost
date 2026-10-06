import CoreGraphics

/// Filters out leftover status bar windows of apps that have quit (macos-behavior.md, "Task 4"): after an app
/// quits, its status bar window may remain in CGWindowList (measured: width 0, `onscreen=false`).
///
/// Rule: no ownership (no AX match, and no cached ownership by a live process) **and** not on screen **and**
/// zero width. All three are required: pushed-out items are also `onscreen=false` and their ownership may be
/// temporarily unresolved, but they have a normal width and must be kept.
public enum StaleWindowFilter {
    /// Possibly a leftover window (ignoring ownership): not on screen and zero width. Such windows aren't worth
    /// triggering a full AX read for.
    public static func isCandidate(_ window: RawStatusWindow) -> Bool {
        !window.isOnScreen && window.frame.width < 1
    }

    /// The leftover check after ownership has been merged.
    public static func isStale(_ item: MenuBarItem) -> Bool {
        item.bundleID == nil && !item.isOnScreen && item.frame.width < 1
    }

    /// Drops cached ownership whose process has quit: a leftover window keeps its windowID, so otherwise it would
    /// keep the ownership it had before the app quit.
    public static func ownershipOfLiveProcesses(_ cache: [CGWindowID: AXItemInfo],
                                                isAlive: (pid_t) -> Bool) -> [CGWindowID: AXItemInfo] {
        var alive: [pid_t: Bool] = [:]
        return cache.filter { _, info in
            if let known = alive[info.pid] { return known }
            let result = isAlive(info.pid)
            alive[info.pid] = result
            return result
        }
    }
}
