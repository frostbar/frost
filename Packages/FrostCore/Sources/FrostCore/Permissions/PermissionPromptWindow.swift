import CoreGraphics
import Foundation

/// One window as `CGWindowListCopyWindowInfo` reports it, reduced to what prompt detection needs.
public struct WindowSnapshot: Equatable, Sendable {
    public let windowID: CGWindowID
    public let ownerName: String?
    public let ownerPID: pid_t
    /// Path of the owning process's executable (nil when it can't be resolved). The window list doesn't carry it, so
    /// the caller resolves it once per process (`NSRunningApplication.executableURL`).
    public let ownerExecutablePath: String?
    public let isOnScreen: Bool

    public init(windowID: CGWindowID, ownerName: String?, ownerPID: pid_t, ownerExecutablePath: String?,
                isOnScreen: Bool) {
        self.windowID = windowID
        self.ownerName = ownerName
        self.ownerPID = ownerPID
        self.ownerExecutablePath = ownerExecutablePath
        self.isOnScreen = isOnScreen
    }

    /// Reads one entry of `CGWindowListCopyWindowInfo`. Entries without a window number or an owner PID (they are not
    /// windows Frost could compare) return nil.
    public init?(windowInfo: [String: Any], ownerExecutablePath: String?) {
        guard let number = windowInfo[kCGWindowNumber as String] as? Int,
              let windowID = CGWindowID(exactly: number),
              let rawPID = windowInfo[kCGWindowOwnerPID as String] as? Int else { return nil }
        self.init(windowID: windowID,
                  ownerName: windowInfo[kCGWindowOwnerName as String] as? String,
                  ownerPID: pid_t(rawPID),
                  ownerExecutablePath: ownerExecutablePath,
                  // A list that doesn't report the flag (e.g. a filtered one) is not evidence of a visible window.
                  isOnScreen: (windowInfo[kCGWindowIsOnscreen as String] as? Bool) ?? false)
    }
}

/// Whether the system's permission prompt is on screen. Frost asks for Screen Recording through
/// `CGRequestScreenCaptureAccess`, which only prompts once per process and only while TCC has no entry for the app;
/// when no prompt appeared, Frost is already listed and it opens the Settings pane instead (see `PermissionRequest`).
///
/// The prompt is a window of the `universalAccessAuthWarn` process on macOS 26. Matching that one process name is
/// brittle: a future macOS could rename it, and Frost would then open the Settings pane *on top of* the prompt, which
/// is the bug this detection exists to prevent (the prompt resurfaces over the pane after the grant). Detection
/// therefore has two rules:
///
/// 1. A window whose owner is one of `promptOwnerNames` is the prompt.
/// 2. Any other window that **appeared after the request** (its ID is not in the baseline taken just before the
///    request), is on screen, is owned by an executable under `/System/`, and whose owner is not one of the
///    always-present system processes in `ignoredOwnerNames`. The baseline is what keeps rule 2 from firing on the
///    menu bar, the Dock and every other window that was already there; the ignore list covers always-present
///    processes that open an extra window after the request (a Notification Center banner, the Dock's window list).
///
/// Rule 2 is a heuristic over unrelated windows, so it stays silent unless the window could plausibly be system UI:
/// an ordinary app's window, a window with no resolvable owner, and an off-screen window never count.
extension PermissionRequest {
    /// Always-present system processes whose windows are never the permission prompt, so the fallback in
    /// `promptVisible(baseline:current:)` doesn't mistake one of their new windows for it.
    public static let ignoredOwnerNames: Set<String> = [
        "System Settings", "Frost", "Dock", "WindowServer", "Control Center",
        "Notification Center", "Spotlight", "SystemUIServer", "loginwindow",
    ]

    /// Whether a permission prompt is on screen now, given the windows that were on screen just before the request.
    public static func promptVisible(baseline: [WindowSnapshot], current: [WindowSnapshot]) -> Bool {
        let before = Set(baseline.map(\.windowID))
        return current.contains { isPromptWindow($0, appearingSince: before) }
    }

    /// One window, judged against the window IDs on screen before the request.
    static func isPromptWindow(_ window: WindowSnapshot, appearingSince before: Set<CGWindowID>) -> Bool {
        guard window.isOnScreen else { return false }
        if isPromptWindow(ownerName: window.ownerName) { return true }
        // Rule 2 (see above): a window that is new since the request, from a system process Frost doesn't know to be
        // always present. Everything that was already up (the menu bar, the Dock, ...) stays out.
        guard !before.contains(window.windowID),
              let ownerName = window.ownerName, !ignoredOwnerNames.contains(ownerName),
              let path = window.ownerExecutablePath, path.hasPrefix("/System/") else { return false }
        return true
    }
}
