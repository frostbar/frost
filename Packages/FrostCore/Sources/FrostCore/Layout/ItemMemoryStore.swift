import CoreGraphics
import Foundation

/// What Frost remembers about menu bar icons across launches, persisted in UserDefaults: the icons seen so far
/// (`NewItemPlacement`), the section the user keeps each icon in and the icons Frost must move back
/// (`SectionKeeper`), and the window title last seen with each identity (`IdentityMigration`). `NewItemPlacer` (app
/// layer) owns one and decides with it; this type holds the persistence and the launch-time migration so that upgrades
/// from data earlier releases stored can be tested through the same path.
///
/// Loading reads every format earlier releases wrote: version 1 (keyed by window title, 0.2.x) is read as legacy
/// identities when no version 2 data exists, and left in place. Data stored under an older identity (a window title,
/// an AX description that has changed, a key with live numbers from before they were normalized) is moved to the
/// current items' identities by `migrateIdentities`, which runs before every decision.
@MainActor
public final class ItemMemoryStore {
    private let defaults: UserDefaults

    /// Seen icons (`NewItemPlacement.encode`, version 2: AX-derived identities). Version 1 (`knownItemIdentities`,
    /// keyed by window title) is read once as legacy identities and left in place.
    private static let knownKey = "knownItemIdentities.v2"
    private static let knownKeyV1 = "knownItemIdentities"
    /// Frost's first run (AH seed just written) with no decision made yet: move existing Always Hidden icons to Hidden.
    private static let firstRunKey = "firstRunPlacementPending"
    /// The remembered section of each icon (`SectionKeeper.encode`); the suffix is the format version. Version 1 (keyed
    /// by window title) is read once as legacy identities and left in place.
    private static let sectionsKey = "itemSections.v2"
    private static let sectionsKeyV1 = "itemSections.v1"
    /// The window title last seen with each identity (`IdentityMigration.encodeTitles`).
    private static let titlesKey = "itemTitles.v1"
    /// Icons Frost moved out temporarily and must move back (`SectionKeeper.pendingReturns`, `PendingReturn.encode`: the
    /// remembered sections' format, as 0.3.2 stored it, plus each icon's neighbours): written before the background
    /// capture moves an item out, removed once it is back.
    private static let pendingReturnsKey = "pendingItemReturns.v1"

    /// Icons seen so far; nil means the first scan hasn't happened yet (seeded on the next decision).
    public private(set) var known: Set<ItemIdentity>?
    /// The remembered sections and this run's observations.
    public private(set) var keeper: SectionKeeper
    /// The window title last seen with each identity (only readable with Screen Recording): lets remembered state
    /// follow an item whose AX description changed (`IdentityMigration`).
    public private(set) var titles: [ItemIdentity: String] = [:]
    /// Returns recorded during this run (`notePendingReturn`); the ones loaded at launch are in `keeper`. Both are
    /// persisted together.
    private var runPendingReturns: [ItemIdentity: PendingReturn] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        known = defaults.data(forKey: Self.knownKey).flatMap { try? NewItemPlacement.decode($0) }
            ?? defaults.data(forKey: Self.knownKeyV1).flatMap { try? NewItemPlacement.decodeLegacy($0) }
        var memory: [ItemIdentity: MenuBarSection] = [:]
        do {
            if let data = defaults.data(forKey: Self.sectionsKey) {
                memory = try SectionKeeper.decode(data)
            } else if let data = defaults.data(forKey: Self.sectionsKeyV1) {
                memory = try SectionKeeper.decodeLegacy(data)
                FrostLog.newItems.notice("""
                    read \(memory.count) remembered section(s) keyed by window title; they move to Accessibility-based \
                    identities as the items are seen
                    """)
            }
        } catch {
            FrostLog.newItems.error("failed to read the remembered sections: \(error, privacy: .public)")
        }
        let pending = defaults.data(forKey: Self.pendingReturnsKey).flatMap { try? PendingReturn.decode($0) } ?? [:]
        if !pending.isEmpty {
            FrostLog.newItems.notice("\(pending.count) item(s) Frost moved out temporarily before quitting go back")
        }
        keeper = SectionKeeper(memory: memory, pendingReturns: pending)
        titles = defaults.data(forKey: Self.titlesKey).flatMap { try? IdentityMigration.decodeTitles($0) } ?? [:]
    }

    /// Called by SectionController when it first writes the AH seed.
    public static func markFirstRun(defaults: UserDefaults) {
        defaults.set(true, forKey: firstRunKey)
    }

    /// First run: existing icons are still in Always Hidden and will move to Hidden once Accessibility is granted.
    public var isFirstRunPlacementPending: Bool {
        known == nil && defaults.bool(forKey: Self.firstRunKey)
    }

    // MARK: - Deciding

    /// Moves remembered sections and seen icons stored under an older identity (keyed by window title, or an AX
    /// description that has since changed) to the identities the current items have, and records the items' window
    /// titles for the next time (`IdentityMigration`).
    public func migrateIdentities(_ items: [MenuBarItem]) {
        let memoryPlan = IdentityMigration.plan(stored: Set(keeper.memory.keys), titles: titles, items: items)
        if keeper.rekey(memoryPlan) {
            FrostLog.newItems.notice("moved \(memoryPlan.count) remembered section(s) to the items' current identities")
            saveSections()
        }
        if let known {
            let knownPlan = IdentityMigration.plan(stored: known, titles: titles, items: items)
            let migrated = IdentityMigration.apply(knownPlan, to: known)
            if migrated != known {
                self.known = migrated
                saveKnown(migrated)
            }
        }
        let renamed = IdentityMigration.apply(memoryPlan, to: titles)
        if let updated = IdentityMigration.updatedTitles(renamed, items: items) {
            saveTitles(updated)
        } else if renamed != titles {
            saveTitles(renamed)
        }
    }

    /// Decides which new icons to move out of Always Hidden (`NewItemPlacement.decide`, on a collapsed layout) and
    /// remembers the icons it learned. Items whose app still has title-keyed identities that couldn't be mapped (no
    /// Screen Recording) count as seen: whether one of them is new can't be told. Ends Frost's first run.
    public func decideNewItems(layout: MenuBarLayout, items: [MenuBarItem],
                               considered: Set<CGWindowID>) -> NewItemPlacement.Decision {
        let firstRun = known == nil && defaults.bool(forKey: Self.firstRunKey)
        let presumed = known.map { IdentityMigration.presumedKnown(known: $0, items: items) } ?? []
        let decision = NewItemPlacement.decide(layout: layout, known: known.map { $0.union(presumed) },
                                               considered: considered, firstRun: firstRun)
        remember(decision.learned, seeding: known == nil)
        defaults.removeObject(forKey: Self.firstRunKey)
        if firstRun, !decision.toMove.isEmpty {
            FrostLog.newItems.notice("first run: moving \(decision.toMove.count) pre-existing items from Always Hidden to Hidden")
        }
        return decision
    }

    /// Feeds a trustworthy layout to the `SectionKeeper` (`SectionKeeper.observe`; items that may still take over a
    /// title-keyed remembered section once titles are readable aren't seeded) and saves what changed.
    public func observeSections(layout: MenuBarLayout, items: [MenuBarItem], obscured: Set<CGWindowID>,
                                movedByFrost: Set<CGWindowID>, skipping: Set<CGWindowID>, restoreEnabled: Bool,
                                canMove: Bool) -> SectionKeeper.Outcome {
        let awaiting = IdentityMigration.awaitingMigration(stored: Set(keeper.memory.keys), items: items)
        let outcome = keeper.observe(layout: layout, obscured: obscured, movedByFrost: movedByFrost,
                                     skipping: skipping, awaitingMigration: awaiting,
                                     restoreEnabled: restoreEnabled, canMove: canMove)
        if outcome.memoryChanged { saveSections() }
        if outcome.pendingReturnsChanged { savePendingReturns() }
        return outcome
    }

    // MARK: - Recording

    /// Marks icons as seen (`seeding`: the first decision, which records the seen set even when it is empty).
    public func remember(_ identities: Set<ItemIdentity>, seeding: Bool) {
        guard seeding || !identities.isEmpty else { return }
        let updated = (known ?? []).union(identities)
        guard updated != known else { return }
        known = updated
        saveKnown(updated)
    }

    /// Records that `item` now belongs to `section` (`SectionKeeper.record`) and saves it. Returns false (nothing
    /// recorded) when its identity is unresolved or shared by several of `items`.
    @discardableResult
    public func record(_ item: MenuBarItem, in section: MenuBarSection, among items: [MenuBarItem]) -> Bool {
        guard keeper.record(item, in: section, among: items) else { return false }
        saveSections()
        return true
    }

    /// Records the sections of new icons Frost placed (they belong there until the user moves them).
    public func recordPlaced(_ placed: [(item: MenuBarItem, section: MenuBarSection)], among items: [MenuBarItem]) {
        for placement in placed { keeper.record(placement.item, in: placement.section, among: items) }
        if !placed.isEmpty { saveSections() }
    }

    /// Restores of these items were attempted (moved or failed): `SectionKeeper.restoreAttempted`.
    public func restoresAttempted(_ items: [MenuBarItem]) {
        var returnsChanged = false
        for item in items {
            if keeper.restoreAttempted(item.windowID, identity: item.identity) { returnsChanged = true }
        }
        if returnsChanged { savePendingReturns() }
    }

    /// Frost is about to move `item` out of its slot in `layout` (trusted, collapsed) temporarily: records that it must go
    /// back there, so that if Frost quits before it can, the next launch moves it back into that slot
    /// (`SectionKeeper.pendingReturns`, `PendingReturn`). Returns the identity recorded (nil: unresolved, shared with
    /// another of `items` or not in `layout`; nothing recorded).
    public func notePendingReturn(of item: MenuBarItem, in layout: MenuBarLayout,
                                  among items: [MenuBarItem]) -> ItemIdentity? {
        guard let identity = item.identity, items.filter({ $0.identity == identity }).count <= 1,
              let slot = PendingReturn.make(for: item, in: layout) else { return nil }
        runPendingReturns[identity] = slot
        savePendingReturns()
        return identity
    }

    /// The item recorded by `notePendingReturn` is back (or gone).
    public func clearPendingReturn(_ identity: ItemIdentity?) {
        guard let identity, runPendingReturns.removeValue(forKey: identity) != nil else { return }
        savePendingReturns()
    }

    // MARK: - Saving

    private func savePendingReturns() {
        let all = keeper.pendingReturns.merging(runPendingReturns) { _, run in run }
        guard !all.isEmpty else {
            defaults.removeObject(forKey: Self.pendingReturnsKey)
            return
        }
        do {
            defaults.set(try PendingReturn.encode(all), forKey: Self.pendingReturnsKey)
        } catch {
            FrostLog.newItems.error("failed to save the items to move back: \(error, privacy: .public)")
        }
    }

    private func saveTitles(_ updated: [ItemIdentity: String]) {
        titles = updated
        do {
            defaults.set(try IdentityMigration.encodeTitles(updated), forKey: Self.titlesKey)
        } catch {
            FrostLog.newItems.error("failed to save item titles: \(error, privacy: .public)")
        }
    }

    private func saveKnown(_ identities: Set<ItemIdentity>) {
        do {
            defaults.set(try NewItemPlacement.encode(identities), forKey: Self.knownKey)
        } catch {
            FrostLog.newItems.error("failed to save known items: \(error, privacy: .public)")
        }
    }

    private func saveSections() {
        do {
            defaults.set(try SectionKeeper.encode(keeper.memory), forKey: Self.sectionsKey)
        } catch {
            FrostLog.newItems.error("failed to save the remembered sections: \(error, privacy: .public)")
        }
    }
}
