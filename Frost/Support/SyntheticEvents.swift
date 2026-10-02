import AppKit

/// Mouse events Frost synthesizes itself (a move's ⌘-drag, a forwarded click) also reach Frost's own event monitors.
/// Monitors that react to "the user clicked somewhere" (close the Frost Bar, collapse on an outside click) must ignore
/// them, or a new item placed while the Frost Bar is open would close it.
enum SyntheticEvents {
    /// Whether `event` was posted by this process (`CGEvent` records the posting process).
    static func isPostedByFrost(_ event: NSEvent) -> Bool {
        guard let cgEvent = event.cgEvent else { return false }
        return cgEvent.getIntegerValueField(.eventSourceUnixProcessID) == Int64(ProcessInfo.processInfo.processIdentifier)
    }
}
