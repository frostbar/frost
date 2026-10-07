import CoreGraphics
import Foundation

/// Where an icon Frost moved out temporarily (the background capture of items behind the notch) must go back to if
/// Frost quits before it can move it back itself (`SectionKeeper.pendingReturns`): its section and the identities of
/// its neighbours in that section at move-out time, so the next launch puts it back into its exact slot rather than at
/// the section's edge.
///
/// Window IDs don't survive a relaunch of Frost or of the apps, so the slot is kept by identity (`ItemIdentity`), like
/// `RestorePlan` keeps it by window ID within a run. Moving back prefers the same anchors as `RestorePlan`: left of the
/// right neighbour, else right of the left neighbour, else the section boundary (`SectionKeeper.destination`), each only
/// while that neighbour is still in the section and its identity names a single item.
///
/// Persisted as 0.3.2 stored a pending return (`{bundleID, key, section}`), with optional `right` / `left` neighbour
/// identities: 0.3.2's data reads as returns to the section's edge, and 0.3.2 reads this format (ignoring the
/// neighbours) after a downgrade.
public struct PendingReturn: Hashable, Sendable {
    public var section: MenuBarSection
    /// The icon immediately right of it in `section` (nil: none, or not uniquely identifiable).
    public var rightNeighbour: ItemIdentity?
    /// The icon immediately left of it in `section` (nil: none, or not uniquely identifiable).
    public var leftNeighbour: ItemIdentity?

    public init(section: MenuBarSection, rightNeighbour: ItemIdentity? = nil, leftNeighbour: ItemIdentity? = nil) {
        self.section = section
        self.rightNeighbour = rightNeighbour
        self.leftNeighbour = leftNeighbour
    }

    /// `item`'s slot in `layout` (a trusted, collapsed layout): its section and its neighbours there. A neighbour whose
    /// identity is unresolved or shared by several items of the layout isn't recorded. nil if `item` isn't in `layout`.
    public static func make(for item: MenuBarItem, in layout: MenuBarLayout) -> PendingReturn? {
        let unique = uniqueIdentities(in: layout)
        for section in MenuBarSection.leftToRight {
            let items = layout[section, default: []]
            guard let index = items.firstIndex(where: { $0.windowID == item.windowID }) else { continue }
            func neighbour(_ offset: Int) -> ItemIdentity? {
                guard items.indices.contains(index + offset), let identity = items[index + offset].identity,
                      unique[identity] != nil else { return nil }
                return identity
            }
            return PendingReturn(section: section, rightNeighbour: neighbour(1), leftNeighbour: neighbour(-1))
        }
        return nil
    }

    /// The move that puts the icon (`itemID`, now elsewhere) back into its slot in `layout` (the current one).
    public func destination(for itemID: CGWindowID, in layout: MenuBarLayout,
                            controls: FrostControlWindows) -> MoveDestination {
        let unique = Self.uniqueIdentities(in: [section: layout[section, default: []].filter { $0.windowID != itemID }])
        if let right = rightNeighbour.flatMap({ unique[$0] }) { return .leftOf(right) }
        if let left = leftNeighbour.flatMap({ unique[$0] }) { return .rightOf(left) }
        return SectionKeeper.destination(for: section, controls: controls)
    }

    /// identity → window, for the identities exactly one item of `layout` has.
    private static func uniqueIdentities(in layout: MenuBarLayout) -> [ItemIdentity: CGWindowID] {
        var windows: [ItemIdentity: [CGWindowID]] = [:]
        for item in layout.values.joined() {
            if let identity = item.identity { windows[identity, default: []].append(item.windowID) }
        }
        return windows.compactMapValues { $0.count == 1 ? $0[0] : nil }
    }

    // MARK: - Persistence

    private struct Entry: Codable {
        var bundleID: String
        var key: String
        var section: MenuBarSection
        var right: ItemIdentity?
        var left: ItemIdentity?
    }

    /// A JSON array of `{bundleID, key, section, right?, left?}` sorted by bundleID, then key (stable contents); an entry
    /// without neighbours is exactly what 0.3.2 stored.
    public static func encode(_ returns: [ItemIdentity: PendingReturn]) throws -> Data {
        let entries = returns
            .map { Entry(bundleID: $0.key.bundleID, key: $0.key.key, section: $0.value.section,
                         right: $0.value.rightNeighbour, left: $0.value.leftNeighbour) }
            .sorted { ($0.bundleID, $0.key) < ($1.bundleID, $1.key) }
        return try JSONEncoder().encode(entries)
    }

    /// Reads `encode`'s format and 0.3.2's (no neighbours: back to the section's edge).
    public static func decode(_ data: Data) throws -> [ItemIdentity: PendingReturn] {
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        return Dictionary(entries.map {
            (ItemIdentity(bundleID: $0.bundleID, key: $0.key),
             PendingReturn(section: $0.section, rightNeighbour: $0.right, leftNeighbour: $0.left))
        }, uniquingKeysWith: { _, last in last })
    }
}
