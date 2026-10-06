import Foundation

/// Maps remembered identities (section memory, known items, disk cache entries) to the identities the current items
/// have, so that state keyed by an older identity isn't lost.
///
/// Two cases:
/// - **Legacy identities**: before identities were derived from AX attributes (`ItemIdentityKey`), they were bundle
///   ID + window title. Persisted data in that format is loaded as `title:<title>` keys (`legacy(bundleID:title:)`).
/// - **Changed keys**: an item's AX description (part of its key) may change between launches.
/// - **Earlier encoding**: keys written before descriptions were escaped (`ItemIdentityKey.unescapedEncoding`); only
///   descriptions containing `#` or `\` differ.
/// - **Numbers**: keys written before numbers in descriptions and help texts were normalized
///   (`ItemIdentityKey.numberedKeys`), possibly with a live reading that has changed since.
///
/// For each current item with a resolved identity that isn't remembered yet (and that no other current item shares),
/// a remembered identity of the same app is taken over when one of these holds (in this order):
/// 0. Its key in the earlier encoding is remembered and no other current item had that key.
/// 0a. Its key with numbers kept (`MenuBarItem.numberedIdentityKey`) is remembered and no other current item has that
///     numbered key (items that now share a text, like `Fan 1` and `Fan 2`, keep their own entries).
/// 0b. Remembered keys of the same app become its key once their numbers are normalized
///     (`ItemIdentityKey.numberNormalizedEncoding`): the item's reading changed since. All of them map to it (an
///     earlier version may have remembered a live item of a multi-item app under several readings; `apply` keeps their
///     value only when they agree).
/// 1. Its window title is known (Screen Recording) and matches a legacy identity's title, or the title last seen with a
///    remembered identity (`titles`).
/// 2. It is the app's only current item and the app has exactly one remembered identity that no current item has (no
///    title needed: works with Accessibility alone).
///
/// Each remembered identity is mapped at most once, and only rule 0b maps several onto one identity. Unmapped legacy
/// identities stay as they are (they may map later, once titles become readable).
public enum IdentityMigration {
    public static let legacyPrefix = "title:"

    /// A pre-AX identity: bundle ID + window title.
    public static func legacy(bundleID: String, title: String) -> ItemIdentity {
        ItemIdentity(bundleID: bundleID, key: legacyPrefix + title)
    }

    /// Old identity → the current identity it becomes. `stored` are the remembered identities; `titles` the window
    /// title last seen with each of them.
    public static func plan(stored: Set<ItemIdentity>, titles: [ItemIdentity: String] = [:],
                            items: [MenuBarItem]) -> [ItemIdentity: ItemIdentity] {
        let resolved = items.compactMap { item in item.identity.map { (item: item, identity: $0) } }
        let identityCounts = Dictionary(resolved.map { ($0.identity, 1) }, uniquingKeysWith: +)
        let current = Set(identityCounts.keys)
        var titleCounts: [String: [String: Int]] = [:]
        for entry in resolved where !entry.item.windowTitle.isEmpty {
            titleCounts[entry.identity.bundleID, default: [:]][entry.item.windowTitle, default: 0] += 1
        }
        let itemsPerApp = Dictionary(resolved.map { ($0.identity.bundleID, 1) }, uniquingKeysWith: +)
        // Remembered identities no current item has: the candidates to take over.
        var available = stored.subtracting(current)
        let earlier: [ItemIdentity: ItemIdentity] = Dictionary(uniqueKeysWithValues: current.compactMap { identity in
            ItemIdentityKey.unescapedEncoding(of: identity.key)
                .map { (identity, ItemIdentity(bundleID: identity.bundleID, key: $0)) }
        })
        let earlierCounts = Dictionary(earlier.values.map { ($0, 1) }, uniquingKeysWith: +)
        let numbered = resolved.compactMap { entry in
            entry.item.numberedIdentityKey.map { ItemIdentity(bundleID: entry.identity.bundleID, key: $0) }
        }
        let numberedCounts = Dictionary(numbered.map { ($0, 1) }, uniquingKeysWith: +)
        let normalizedStored: [ItemIdentity: String] = Dictionary(uniqueKeysWithValues: available.compactMap { old in
            ItemIdentityKey.numberNormalizedEncoding(of: old.key).map { (old, $0) }
        })
        var plan: [ItemIdentity: ItemIdentity] = [:]

        func take(_ old: ItemIdentity, for new: ItemIdentity) {
            plan[old] = new
            available.remove(old)
        }

        for (item, identity) in resolved
        where identityCounts[identity] == 1 && !stored.contains(identity) && !plan.values.contains(identity) {
            if let old = earlier[identity], earlierCounts[old] == 1, available.contains(old) {
                take(old, for: identity)
                continue
            }
            if let key = item.numberedIdentityKey {
                let old = ItemIdentity(bundleID: identity.bundleID, key: key)
                if numberedCounts[old] == 1, available.contains(old) {
                    take(old, for: identity)
                    continue
                }
            }
            let readings = available.filter { $0.bundleID == identity.bundleID && normalizedStored[$0] == identity.key }
            if !readings.isEmpty {
                for old in readings { take(old, for: identity) }
                continue
            }
            let title = item.windowTitle
            if !title.isEmpty, titleCounts[identity.bundleID]?[title] == 1 {
                let legacyIdentity = legacy(bundleID: identity.bundleID, title: title)
                if available.contains(legacyIdentity) {
                    take(legacyIdentity, for: identity)
                    continue
                }
                let renamed = available.filter { $0.bundleID == identity.bundleID && titles[$0] == title }
                if renamed.count == 1, let old = renamed.first {
                    take(old, for: identity)
                    continue
                }
            }
            if itemsPerApp[identity.bundleID] == 1 {
                let sole = available.filter { $0.bundleID == identity.bundleID }
                if stored.filter({ $0.bundleID == identity.bundleID }).count == 1, let old = sole.first,
                   sole.count == 1 {
                    take(old, for: identity)
                }
            }
        }
        return plan
    }

    /// `values` with the keys `plan` maps moved to their new identities. An existing entry for the new identity wins;
    /// when several old identities map to one new identity, their value moves only if they all have the same one
    /// (otherwise which is current can't be told, and none is kept).
    public static func apply<Value: Equatable>(_ plan: [ItemIdentity: ItemIdentity],
                                               to values: [ItemIdentity: Value]) -> [ItemIdentity: Value] {
        guard !plan.isEmpty else { return values }
        var result = values
        for (new, pairs) in Dictionary(grouping: plan, by: \.value) {
            let moved = pairs.compactMap { result.removeValue(forKey: $0.key) }
            guard result[new] == nil, let value = moved.first, moved.allSatisfy({ $0 == value }) else { continue }
            result[new] = value
        }
        return result
    }

    /// `identities` with the members `plan` maps replaced by their new identities.
    public static func apply(_ plan: [ItemIdentity: ItemIdentity], to identities: Set<ItemIdentity>)
        -> Set<ItemIdentity> {
        guard !plan.isEmpty else { return identities }
        return Set(identities.map { plan[$0] ?? $0 })
    }

    /// Current identities that should count as already seen although they aren't in `known`: items whose app still has
    /// unmapped legacy identities and whose title isn't readable (without Screen Recording they can't be told apart,
    /// so whether one of them is new can't be decided; moving an icon the user put in Always Hidden would be worse
    /// than leaving a new one there).
    public static func presumedKnown(known: Set<ItemIdentity>, items: [MenuBarItem]) -> Set<ItemIdentity> {
        awaitingMigration(stored: known, items: items)
    }

    /// Current identities that may still take over one of the `stored` legacy identities once titles are readable:
    /// items whose app has unmapped legacy identities and whose title isn't readable. Nothing may be stored under them
    /// meanwhile (`SectionKeeper.observe`'s `awaitingMigration`): `plan` never maps onto an identity already stored, so
    /// a section seeded from where the item happens to be now would win over the one the user chose.
    public static func awaitingMigration(stored: Set<ItemIdentity>, items: [MenuBarItem]) -> Set<ItemIdentity> {
        let known = stored
        let legacyApps = Set(known.filter(\.isLegacy).map(\.bundleID))
        guard !legacyApps.isEmpty else { return [] }
        return Set(items.compactMap { item in
            guard item.windowTitle.isEmpty, let identity = item.identity, !known.contains(identity),
                  legacyApps.contains(identity.bundleID) else { return nil }
            return identity
        })
    }

    // MARK: - Persistence

    private struct TitleEntry: Codable {
        var bundleID: String
        var key: String
        var title: String
    }

    /// The window titles last seen with each identity (`plan`'s `titles`): a JSON array sorted by bundle ID, then key.
    public static func encodeTitles(_ titles: [ItemIdentity: String]) throws -> Data {
        let entries = titles.map { TitleEntry(bundleID: $0.key.bundleID, key: $0.key.key, title: $0.value) }
            .sorted { ($0.bundleID, $0.key) < ($1.bundleID, $1.key) }
        return try JSONEncoder().encode(entries)
    }

    public static func decodeTitles(_ data: Data) throws -> [ItemIdentity: String] {
        let entries = try JSONDecoder().decode([TitleEntry].self, from: data)
        return Dictionary(entries.map { (ItemIdentity(bundleID: $0.bundleID, key: $0.key), $0.title) },
                          uniquingKeysWith: { _, last in last })
    }

    /// Records the window titles of the current items with a unique identity; returns nil when nothing changed.
    public static func updatedTitles(_ titles: [ItemIdentity: String], items: [MenuBarItem])
        -> [ItemIdentity: String]? {
        let resolved = items.compactMap { item in item.identity.map { ($0, item.windowTitle) } }
        let counts = Dictionary(resolved.map { ($0.0, 1) }, uniquingKeysWith: +)
        var result = titles
        for (identity, title) in resolved where !title.isEmpty && counts[identity] == 1 {
            result[identity] = title
        }
        return result == titles ? nil : result
    }
}
