import CoreGraphics
import Foundation

/// A new app's icon lands at the far left of all status items by default (it has no Preferred Position), i.e. in
/// the "always hidden" section left of the AH separator (seed 10000) — where the user can't see it. Frost remembers
/// the icons it has seen (`ItemIdentity`); when a never-seen icon shows up in the always-hidden section, it is
/// moved to the hidden section (`.leftOf(H)`).
///
/// - First time (`known == nil`): mark every current icon as seen and move nothing (including icons the user put
///   in the always-hidden section themselves).
/// - Frost's first run (`firstRun` and `known == nil`): most existing icons have no Preferred Position, and the
///   system places them left of AH (measured in the VM: unseeded items always sit left of seeded ones, regardless
///   of AH's value). The user can't have put anything in the always-hidden section yet, so every movable, resolved
///   item there is moved to the hidden section; unresolved items are not marked as considered and are treated as
///   "never seen" once resolved.
/// - Icons whose owner is unresolved can't be checked against the seen set: wait until they resolve.
/// - `considered`: windows already handled during this run (present at seeding time, or already decided not to
///   move); if they resolve later they are only marked as seen, never moved.
public enum NewItemPlacement {
    public struct Decision: Equatable, Sendable {
        /// Icons newly marked as seen (no move needed).
        public var learned: Set<ItemIdentity> = []
        /// Icons to move from the always-hidden section to the hidden section (left to right); the caller marks
        /// them as seen after the move attempt.
        public var toMove: [MenuBarItem] = []
        /// The updated set of considered windows.
        public var considered: Set<CGWindowID> = []
    }

    /// A stable identity needs the real owner and its AX-derived key (`MenuBarItem.identity`); nil while unresolved.
    public static func identity(of item: MenuBarItem) -> ItemIdentity? {
        item.identity
    }

    /// `layout` must be a trustworthy layout (collapsed, not editing: on a crowded notched display while expanded,
    /// items that don't fit get placed left of AH).
    public static func decide(layout: MenuBarLayout, known: Set<ItemIdentity>?,
                              considered: Set<CGWindowID>, firstRun: Bool = false) -> Decision {
        let items = MenuBarSection.leftToRight.flatMap { layout[$0, default: []] }
        var decision = Decision(considered: considered)
        if known == nil, firstRun {
            // Same as "nothing seen yet": move items out of the always-hidden section, mark the rest as seen.
            return decide(layout: layout, known: [], considered: considered)
        }
        guard let known else {
            decision.learned = Set(items.compactMap(identity(of:)))
            decision.considered.formUnion(items.map(\.windowID))
            return decision
        }
        let alwaysHidden = Set(layout[.alwaysHidden, default: []].map(\.windowID))
        for item in items {
            let identity = identity(of: item)
            if considered.contains(item.windowID) {
                if let identity, !known.contains(identity) { decision.learned.insert(identity) }
                continue
            }
            guard let identity else { continue }
            if known.contains(identity) {
                decision.considered.insert(item.windowID)
            } else if alwaysHidden.contains(item.windowID), item.isMovable {
                decision.toMove.append(item)
            } else {
                decision.learned.insert(identity)
                decision.considered.insert(item.windowID)
            }
        }
        return decision
    }

    /// Persistence format (version 2): a JSON array of `{bundleID, key}` (sorted by bundleID, then key, for stable
    /// contents).
    public static func encode(_ identities: Set<ItemIdentity>) throws -> Data {
        try JSONEncoder().encode(identities.sorted { ($0.bundleID, $0.key) < ($1.bundleID, $1.key) })
    }

    public static func decode(_ data: Data) throws -> Set<ItemIdentity> {
        Set(try JSONDecoder().decode([ItemIdentity].self, from: data))
    }

    private struct LegacyIdentity: Codable {
        var bundleID: String
        var title: String
    }

    /// Reads version 1 (`{bundleID, title}`, keyed by window title) as legacy identities (`IdentityMigration.legacy`).
    public static func decodeLegacy(_ data: Data) throws -> Set<ItemIdentity> {
        Set(try JSONDecoder().decode([LegacyIdentity].self, from: data).map {
            IdentityMigration.legacy(bundleID: $0.bundleID, title: $0.title)
        })
    }
}
