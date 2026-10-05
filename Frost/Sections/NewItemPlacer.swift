import AppKit
import FrostCore
import Observation

/// Places icons the system adds to the menu bar: moves new apps' icons from the Always Hidden section to the Hidden
/// section (rules in `NewItemPlacement`), and moves an icon its app re-added in another section back into the section
/// the user keeps it in (rules in `SectionKeeper`).
///
/// A new icon has no Preferred Position, so the system places it leftmost of all status items, i.e. left of the AH
/// separator, where the user can't see it in the menu bar or in the Frost Bar (without ⌥). Seen icons (`ItemIdentity`)
/// are persisted in UserDefaults; the first successful scan marks every current icon as seen. On Frost's very first run,
/// the icons already in Always Hidden are moved to Hidden instead (see `NewItemPlacement`).
///
/// An app whose icon has no stable autosave name (or whose saved position is lost) gets it re-added the same way when it
/// relaunches. The section of every icon is remembered (persisted, `SectionKeeper`): seeded from what Frost sees, and
/// updated when the user moves an icon (a layout editor drop reports it through `recordDrop`; a ⌘-drag in the menu bar is
/// seen as the same window changing section without Frost moving it). When a window Frost hasn't seen in this run shows
/// up in another section, it is moved back, unless the user turned "Keep icons in their sections" off.
///
/// Identities are derived from Accessibility attributes (`ItemIdentityKey`), so all of this works with Accessibility
/// alone. Data persisted by versions that keyed items by window title (Screen Recording) is migrated as items are seen
/// (`IdentityMigration`); the window title last seen with each identity is kept as an extra signal for that.
///
/// Observes only when the layout is trustworthy: Accessibility granted, not editing, no move transaction, no mouse
/// button held (`UserMouseButtons`), and neither separator under the notch (collapsed or expanded). Moves only when the
/// user won't be disturbed: collapsed, user present, the Frost Bar closed and not forwarding a click (`isPaused`).
/// Retries later when moving isn't convenient (checked again before each item of a batch); a failed move is only logged
/// (no retries).
@MainActor
final class NewItemPlacer {
    private let scanner: MenuBarItemScanner
    private let mover: ItemMover
    private let sections: SectionController
    private let permissions: PermissionsService
    private let preferences: Preferences
    private let presence: UserPresenceMonitor
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
    /// Icons Frost moved out temporarily and must move back (`SectionKeeper.pendingReturns`; same format as the
    /// remembered sections): written before the background capture moves an item out, removed once it is back.
    private static let pendingReturnsKey = "pendingItemReturns.v1"

    /// Called by SectionController when it first writes the AH seed.
    static func markFirstRun(defaults: UserDefaults) {
        defaults.set(true, forKey: firstRunKey)
    }

    /// First run: existing icons are still in Always Hidden and will move to Hidden once Accessibility is granted
    /// (onboarding shows a note based on this). Not observable: onboarding re-reads it when permissions change
    /// (the first decision only happens once Accessibility is granted).
    var isFirstRunPlacementPending: Bool {
        known == nil && defaults.bool(forKey: Self.firstRunKey)
    }
    private static let debounce: Duration = .milliseconds(500)
    private static let retryDelay: Duration = .seconds(2)
    /// At most this many moves per move transaction; the rest follow after `retryDelay`, so a long batch (e.g. at login)
    /// never holds the mover for long.
    private static let maxMovesPerBatch = 5

    /// Icons seen so far; nil means the first scan hasn't happened yet (seeded on the next decision).
    private var known: Set<ItemIdentity>?
    /// Windows already handled during this run (see `NewItemPlacement.decide`).
    private var considered: Set<CGWindowID> = []
    /// The remembered sections and this run's observations.
    private var keeper: SectionKeeper
    /// The window title last seen with each identity (only readable with Screen Recording): lets remembered state
    /// follow an item whose AX description changed (`IdentityMigration`).
    private var titles: [ItemIdentity: String] = [:]
    /// Returns recorded during this run (`notePendingReturn`); the ones loaded at launch are in `keeper`. Both are
    /// persisted together.
    private var runPendingReturns: [ItemIdentity: MenuBarSection] = [:]
    /// Identities already logged as ambiguous (logged once each).
    private var loggedAmbiguous: Set<ItemIdentity> = []
    /// A full ownership read happened before seeding (otherwise most icons have no owner yet and seeding is incomplete).
    private var refreshedForSeeding = false
    private var evaluateTask: Task<Void, Never>?
    /// Placement waits while this is true (the Frost Bar is open: moving items would rearrange it under the user's
    /// pointer; or it is forwarding a click, which waits for the mover and would otherwise be starved by the rest of a
    /// batch). Set by the app delegate.
    var isPaused: () -> Bool = { false }

    init(scanner: MenuBarItemScanner, mover: ItemMover, sections: SectionController, permissions: PermissionsService,
         preferences: Preferences, presence: UserPresenceMonitor, defaults: UserDefaults = .standard) {
        self.scanner = scanner
        self.mover = mover
        self.sections = sections
        self.permissions = permissions
        self.preferences = preferences
        self.presence = presence
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
        let pending = defaults.data(forKey: Self.pendingReturnsKey).flatMap { try? SectionKeeper.decode($0) } ?? [:]
        if !pending.isEmpty {
            FrostLog.newItems.notice("\(pending.count) item(s) Frost moved out temporarily before quitting go back")
        }
        keeper = SectionKeeper(memory: memory, pendingReturns: pending)
        titles = defaults.data(forKey: Self.titlesKey).flatMap { try? IdentityMigration.decodeTitles($0) } ?? [:]
    }

    func start() {
        observe()
        schedule(after: Self.debounce)
    }

    /// Re-decides (debounced) when the scan results, section state, permissions, presence or the setting change.
    private func observe() {
        withObservationTracking {
            _ = scanner.items
            _ = sections.state
            _ = sections.isEditing
            _ = permissions.canManageItems
            _ = presence.isAway
            _ = preferences.keepItemSections
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.schedule(after: Self.debounce)
                self.observe()
            }
        }
    }

    private func schedule(after delay: Duration) {
        evaluateTask?.cancel()
        evaluations &+= 1
        let evaluation = evaluations
        isIdle = false
        evaluateTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.evaluate()
            // Idle unless the decision scheduled another one (a retry, the rest of a batch) or a newer one replaced it.
            if self?.evaluations == evaluation { self?.isIdle = true }
        }
    }

    /// No decision is pending or running: the background capture of items behind the notch waits for this, so it
    /// never moves an item while new-item placement or the section memory is about to look at or move items.
    private(set) var isIdle = true
    private var evaluations = 0

    /// A move to make: a new icon to Hidden, or a re-added icon back to its remembered section.
    private struct Placement {
        enum Kind { case new, restore }
        let item: MenuBarItem
        let section: MenuBarSection
        let kind: Kind
    }

    private func evaluate() async {
        guard permissions.canManageItems else { return }
        if known == nil, !refreshedForSeeding {
            await scanner.refreshOwnership()
            refreshedForSeeding = true
        }
        // Accessibility granted (owners and identities readable), scan OK, not editing; `observe` re-triggers a
        // decision when any of these change.
        guard scanner.status == .ok, !sections.isEditing, !presence.isAway,
              let controls = sections.controlWindows else { return }
        guard !mover.isBusy, !UserMouseButtons.isAnyHeld, !isPaused() else {
            // Not a good time to look or move (another move transaction running, mouse held down, the Frost Bar open):
            // check again later.
            schedule(after: Self.retryDelay)
            return
        }
        let layout = SectionAssigner.layout(of: scanner.items, controls: controls)
        guard !layout.isEmpty else { return }
        migrateIdentities(scanner.items)
        let collapsed = sections.state == .collapsed
        var placements: [Placement] = []

        // New icons: only collapsed (on a crowded notched display while expanded, items that don't fit get placed left
        // of AH).
        if collapsed {
            let firstRun = known == nil && defaults.bool(forKey: Self.firstRunKey)
            // Items whose app still has title-keyed identities that couldn't be mapped (no Screen Recording) count as
            // seen: whether one of them is new can't be told.
            let presumed = known.map { IdentityMigration.presumedKnown(known: $0, items: scanner.items) } ?? []
            let decision = NewItemPlacement.decide(layout: layout, known: known.map { $0.union(presumed) },
                                                   considered: considered, firstRun: firstRun)
            considered = decision.considered
            remember(decision.learned, seeding: known == nil)
            defaults.removeObject(forKey: Self.firstRunKey)
            if firstRun, !decision.toMove.isEmpty {
                FrostLog.newItems.notice("first run: moving \(decision.toMove.count) pre-existing items from Always Hidden to Hidden")
            }
            placements += decision.toMove.map { Placement(item: $0, section: .hidden, kind: .new) }
        }

        placements += observeSections(layout: layout, controls: controls, collapsed: collapsed,
                                      skipping: Set(placements.map(\.item.windowID)))
        guard !placements.isEmpty else { return }
        // Move in a task that doesn't inherit cancellation: the rescans during the move change `scanner.items`,
        // which triggers `observe` -> `schedule` and cancels `evaluateTask`. If the move were cancelled with it, these
        // items would be marked as seen and stay in Always Hidden forever.
        // Decisions triggered during the move retry later because of `mover.isBusy`.
        let batch = Array(placements.prefix(Self.maxMovesPerBatch))
        await Task { @MainActor in await self.move(batch, controls: controls) }.value
        if placements.count > batch.count, !mover.isShuttingDown { schedule(after: Self.retryDelay) }
    }

    /// Feeds a trustworthy layout to the `SectionKeeper` (records the user's moves, seeds unknown icons) and returns
    /// the icons to move back into their remembered sections.
    private func observeSections(layout: MenuBarLayout, controls: FrostControlWindows, collapsed: Bool,
                                 skipping: Set<CGWindowID>) -> [Placement] {
        let items = scanner.items
        let displayBounds = scanner.menuBarDisplay?.frame ?? CGDisplayBounds(CGMainDisplayID())
        // A separator under the notch (squeezed there while expanded) makes every section boundary unreliable.
        let separatorsTrusted = [controls.hiddenSeparator, controls.alwaysHiddenSeparator].allSatisfy { id in
            items.first { $0.windowID == id }
                .map { SectionKeeper.separatorIsReliable($0, displayBounds: displayBounds) } ?? false
        }
        guard separatorsTrusted else { return [] }
        let obscured = Set(items.filter { ItemMover.isObscured($0, displayBounds: displayBounds) }.map(\.windowID))
        // Items that may still take over a title-keyed remembered section once titles are readable aren't seeded.
        let awaiting = IdentityMigration.awaitingMigration(stored: Set(keeper.memory.keys), items: items)
        let outcome = keeper.observe(layout: layout, obscured: obscured, movedByFrost: mover.takeMovedWindowIDs(),
                                     skipping: skipping, awaitingMigration: awaiting,
                                     restoreEnabled: preferences.keepItemSections,
                                     canMove: collapsed && !mover.isShuttingDown)
        for move in outcome.userMoves {
            FrostLog.newItems.notice("""
                remembering \(move.identity.bundleID, privacy: .public) \
                (\(move.identity.key, privacy: .private)) in \(move.to.rawValue, privacy: .public): \
                moved by the user from \(move.from.rawValue, privacy: .public)
                """)
        }
        if !outcome.seeded.isEmpty {
            FrostLog.newItems.notice("remembering the sections of \(outcome.seeded.count) item(s) seen for the first time")
        }
        for identity in outcome.ambiguous.subtracting(loggedAmbiguous) {
            FrostLog.newItems.notice("""
                several items of \(identity.bundleID, privacy: .public) share the identity \
                \(identity.key, privacy: .private): not keeping their sections
                """)
        }
        loggedAmbiguous = outcome.ambiguous
        if outcome.memoryChanged { saveSections() }
        if outcome.pendingReturnsChanged { savePendingReturns() }
        return outcome.restores.map { Placement(item: $0.item, section: $0.to, kind: .restore) }
    }

    /// Frost is about to move `item` out of `section` temporarily (the background capture of items behind the notch):
    /// records that it must go back, so that if Frost quits before it can, the next launch moves it back
    /// (`SectionKeeper.pendingReturns`). Returns the identity recorded (nil: unresolved or shared, nothing recorded).
    @discardableResult
    func notePendingReturn(of item: MenuBarItem, to section: MenuBarSection) -> ItemIdentity? {
        guard let identity = item.identity,
              scanner.items.filter({ $0.identity == identity }).count <= 1 else { return nil }
        runPendingReturns[identity] = section
        savePendingReturns()
        return identity
    }

    /// The item recorded by `notePendingReturn` is back (or gone).
    func clearPendingReturn(_ identity: ItemIdentity?) {
        guard let identity, runPendingReturns.removeValue(forKey: identity) != nil else { return }
        savePendingReturns()
    }

    private func savePendingReturns() {
        let all = keeper.pendingReturns.merging(runPendingReturns) { _, run in run }
        guard !all.isEmpty else {
            defaults.removeObject(forKey: Self.pendingReturnsKey)
            return
        }
        do {
            defaults.set(try SectionKeeper.encode(all), forKey: Self.pendingReturnsKey)
        } catch {
            FrostLog.newItems.error("failed to save the items to move back: \(error, privacy: .public)")
        }
    }

    /// The user dropped `item` into `section` in the layout editor and the move succeeded: remember it.
    func recordDrop(_ item: MenuBarItem, in section: MenuBarSection) {
        guard keeper.record(item, in: section, among: scanner.items) else {
            FrostLog.newItems.notice("""
                not remembering the section of dropped item \(item.windowID): \
                its identity is unknown or shared with another item
                """)
            return
        }
        FrostLog.newItems.notice("""
            remembering \(item.bundleID ?? "?", privacy: .public) (\(item.identityKey ?? "?", privacy: .private)) \
            in \(section.rawValue, privacy: .public): dropped in the layout editor
            """)
        saveSections()
    }

    private func move(_ placements: [Placement], controls: FrostControlWindows) async {
        // Placements a move was attempted for (moved or failed): only these are marked as seen / checked. The rest of
        // the batch is decided again later.
        var attempted: [Placement] = []
        var moved: [Placement] = []
        do {
            try await mover.transaction {
                for placement in placements {
                    let item = placement.item
                    // Re-checked before every item: a batch takes about a second per item, and a ⌘-drag must never
                    // start while the user holds a mouse button.
                    if let reason = Self.stopReason(isShuttingDown: mover.isShuttingDown,
                                                    isMouseButtonPressed: UserMouseButtons.isAnyHeld,
                                                    isPaused: isPaused(), isAway: presence.isAway) {
                        FrostLog.newItems.notice("stopped placing items (\(reason, privacy: .public)); the rest are retried later")
                        break
                    }
                    attempted.append(placement)
                    do {
                        try await mover.move(item.windowID,
                                             to: SectionKeeper.destination(for: placement.section, controls: controls))
                        moved.append(placement)
                        switch placement.kind {
                        case .new:
                            FrostLog.newItems.notice("moved new item \(item.bundleID ?? "?", privacy: .public) out of Always Hidden")
                        case .restore:
                            FrostLog.newItems.notice("""
                                moved \(item.bundleID ?? "?", privacy: .public) (\(item.identityKey ?? "?", privacy: .private)) \
                                back to \(placement.section.rawValue, privacy: .public): its app re-added it elsewhere
                                """)
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch ItemMoveError.mouseButtonHeld {
                        // The user held a mouse button throughout: nothing was posted; retry this one later too.
                        attempted.removeLast()
                        FrostLog.newItems.notice("stopped placing items (a mouse button is held); the rest are retried later")
                        break
                    } catch ItemMoveError.controlsDisturbed {
                        // Frost's own icons were dragged (routing fell back to position): stop moving the rest.
                        FrostLog.newItems.error("stopped placing items: Frost's controls were disturbed")
                        break
                    } catch {
                        FrostLog.newItems.error("""
                            failed to move \(item.bundleID ?? "?", privacy: .public) to \
                            \(placement.section.rawValue, privacy: .public): \(error, privacy: .public)
                            """)
                    }
                }
            }
        } catch ItemMoveError.shuttingDown {
            // Frost is quitting: these items aren't marked as seen and are placed on the next launch.
            return
        } catch ItemMoveError.busy {
            // Another transaction just started: retry later (these items aren't marked as seen yet).
            schedule(after: Self.retryDelay)
            return
        } catch is CancellationError {
            // Shouldn't happen (see `evaluate`); if cancelled anyway, don't mark as seen and retry later.
            schedule(after: Self.retryDelay)
            return
        } catch {
            FrostLog.newItems.error("placing items failed: \(error, privacy: .public)")
        }
        let newItems = attempted.filter { $0.kind == .new }.map(\.item)
        considered.formUnion(newItems.map(\.windowID))
        remember(Set(newItems.compactMap(NewItemPlacement.identity(of:))), seeding: false)
        var returnsChanged = false
        for placement in attempted where placement.kind == .restore {
            if keeper.restoreAttempted(placement.item.windowID, identity: placement.item.identity) { returnsChanged = true }
        }
        if returnsChanged { savePendingReturns() }
        // A new icon Frost placed in Hidden belongs there until the user moves it.
        let placedNew = moved.filter { $0.kind == .new }
        for placement in placedNew { keeper.record(placement.item, in: placement.section, among: scanner.items) }
        if !placedNew.isEmpty { saveSections() }
        if attempted.count < placements.count, !mover.isShuttingDown { schedule(after: Self.retryDelay) }
    }

    /// Why the rest of a batch must wait (nil = go on with the next item).
    private static func stopReason(isShuttingDown: Bool, isMouseButtonPressed: Bool, isPaused: Bool,
                                   isAway: Bool) -> String? {
        if isShuttingDown { return "Frost is quitting" }
        if isMouseButtonPressed { return "a mouse button is held" }
        if isPaused { return "the Frost Bar is open or forwarding a click" }
        if isAway { return "the user is away" }
        return nil
    }

    private func remember(_ identities: Set<ItemIdentity>, seeding: Bool) {
        guard seeding || !identities.isEmpty else { return }
        let updated = (known ?? []).union(identities)
        guard updated != known else { return }
        known = updated
        saveKnown(updated)
    }

    /// Moves remembered sections and seen icons stored under an older identity (keyed by window title, or an AX
    /// description that has since changed) to the identities the current items have, and records the items' window
    /// titles for the next time (`IdentityMigration`).
    private func migrateIdentities(_ items: [MenuBarItem]) {
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
