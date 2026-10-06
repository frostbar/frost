import CoreGraphics

public struct AXItemInfo: Hashable, Sendable {
    public let bundleID: String
    public let pid: pid_t
    public let frame: CGRect
    /// The item's AX description, or its AX title when it has no description (text items).
    public let description: String?
    /// The item's AX title (a text item's text).
    public let title: String?
    /// The item's AX identifier, if it has one.
    public let identifier: String?
    /// The identity key among its app's items (`ItemIdentityKey`); nil for Frost's own windows.
    public let identityKey: String?
    /// The identity key with the numbers in its text kept (`ItemIdentityKey.numberedKeys`); nil when it is the same as
    /// `identityKey`.
    public let numberedIdentityKey: String?

    public init(bundleID: String, pid: pid_t, frame: CGRect, description: String?, title: String? = nil,
                identifier: String? = nil, identityKey: String? = nil, numberedIdentityKey: String? = nil) {
        self.bundleID = bundleID
        self.pid = pid
        self.frame = frame
        self.description = description
        self.title = title
        self.identifier = identifier
        self.identityKey = identityKey
        self.numberedIdentityKey = numberedIdentityKey
    }
}

public enum AXItemMatcher {
    public static let tolerance: CGFloat = 4

    /// Finds the index of the non-zero-size candidate in `frames` whose midX is closest to `frame`'s and within
    /// tolerance. Ownership matching (`consensusOwnership`) and click lookup (AXExtrasReader.element) share this rule.
    public static func bestMatch(for frame: CGRect, among frames: [CGRect]) -> Int? {
        frames.indices
            .filter { frames[$0].width > 0 && frames[$0].height > 0 }
            .map { (index: $0, distance: abs(frames[$0].midX - frame.midX)) }
            .filter { $0.distance <= tolerance }
            .min { $0.distance < $1.distance }?
            .index
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
