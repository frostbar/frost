import CoreGraphics

public struct AXItemInfo: Hashable, Sendable {
    public let bundleID: String
    public let pid: pid_t
    public let frame: CGRect
    public let description: String?

    public init(bundleID: String, pid: pid_t, frame: CGRect, description: String?) {
        self.bundleID = bundleID
        self.pid = pid
        self.frame = frame
        self.description = description
    }
}

public enum AXItemMatcher {
    public static let tolerance: CGFloat = 4

    /// Finds the index of the non-zero-size candidate in `frames` whose midX is closest to `frame`'s and within
    /// tolerance. Ownership merging (merge) and click lookup (AXExtrasReader.element) share this rule.
    public static func bestMatch(for frame: CGRect, among frames: [CGRect]) -> Int? {
        frames.indices
            .filter { frames[$0].width > 0 && frames[$0].height > 0 }
            .map { (index: $0, distance: abs(frames[$0].midX - frame.midX)) }
            .filter { $0.distance <= tolerance }
            .min { $0.distance < $1.distance }?
            .index
    }

    /// Attaches AX items (the real owners) to windows by nearest midX; each AX item is used at most once.
    public static func merge(windows: [RawStatusWindow], axItems: [AXItemInfo]) -> [MenuBarItem] {
        var available = axItems
        return windows.map { window in
            let info = bestMatch(for: window.frame, among: available.map(\.frame)).map { available.remove(at: $0) }
            return MenuBarItem(windowID: window.windowID, frame: window.frame, isOnScreen: window.isOnScreen,
                               windowTitle: window.title,
                               bundleID: info?.bundleID, pid: info?.pid, axDescription: info?.description)
        }
    }

    /// The full AX read runs in the background (about 300 ms), during which windows may move (moving, expanding /
    /// collapsing). Matches against window snapshots taken before and after the read, and only accepts windows that
    /// matched the same owner both times: small shifts (an icon to the left changing width) don't matter, while
    /// windows that changed position during the read are not accepted (retried later per
    /// `OwnershipRefreshPolicy`), so a neighbor's ownership is never attached to them. Only returns windows present
    /// in both snapshots.
    public static func consensusOwnership(before: [RawStatusWindow], after: [RawStatusWindow],
                                          axItems: [AXItemInfo]) -> [CGWindowID: AXItemInfo] {
        func owners(_ windows: [RawStatusWindow]) -> [CGWindowID: AXItemInfo] {
            var available = axItems
            var result: [CGWindowID: AXItemInfo] = [:]
            for window in windows {
                guard let index = bestMatch(for: window.frame, among: available.map(\.frame)) else { continue }
                result[window.windowID] = available.remove(at: index)
            }
            return result
        }
        let first = owners(before)
        let second = owners(after)
        return second.filter { id, info in first[id] == info }
    }
}
