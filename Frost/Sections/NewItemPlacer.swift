import AppKit
import FrostCore
import Observation

/// Moves new apps' icons from the Always Hidden section to the Hidden section (rules in `NewItemPlacement`).
///
/// A new icon has no Preferred Position, so the system places it leftmost of all status items, i.e. left of the AH
/// separator, where the user can't see it in the menu bar or in the Frost Bar (without ⌥). Seen icons (`ItemIdentity`)
/// are persisted in UserDefaults; the first successful scan marks every current icon as seen. On Frost's very first run,
/// the icons already in Always Hidden are moved to Hidden instead (see `NewItemPlacement`).
///
/// Decides and moves only when the layout is trustworthy and the user won't be disturbed: all permissions granted,
/// collapsed, not editing, no move transaction, no mouse button held.
/// Retries later when moving isn't convenient; a failed move is only logged (the icon is then marked as seen, no retries).
@MainActor
final class NewItemPlacer {
    private let scanner: MenuBarItemScanner
    private let mover: ItemMover
    private let sections: SectionController
    private let permissions: PermissionsService
    private let defaults: UserDefaults

    private static let knownKey = "knownItemIdentities"
    /// Frost's first run (AH seed just written) with no decision made yet: move existing Always Hidden icons to Hidden.
    private static let firstRunKey = "firstRunPlacementPending"

    /// Called by SectionController when it first writes the AH seed.
    static func markFirstRun(defaults: UserDefaults) {
        defaults.set(true, forKey: firstRunKey)
    }

    /// First run: existing icons are still in Always Hidden and will move to Hidden once all permissions are granted
    /// (onboarding shows a note based on this). Not observable: onboarding re-reads it when permissions change
    /// (the first decision only happens once all permissions are granted).
    var isFirstRunPlacementPending: Bool {
        known == nil && defaults.bool(forKey: Self.firstRunKey)
    }
    private static let debounce: Duration = .milliseconds(500)
    private static let retryDelay: Duration = .seconds(2)

    /// Icons seen so far; nil means the first scan hasn't happened yet (seeded on the next decision).
    private var known: Set<ItemIdentity>?
    /// Windows already handled during this run (see `NewItemPlacement.decide`).
    private var considered: Set<CGWindowID> = []
    /// A full ownership read happened before seeding (otherwise most icons have no owner yet and seeding is incomplete).
    private var refreshedForSeeding = false
    private var evaluateTask: Task<Void, Never>?

    init(scanner: MenuBarItemScanner, mover: ItemMover, sections: SectionController,
         permissions: PermissionsService, defaults: UserDefaults = .standard) {
        self.scanner = scanner
        self.mover = mover
        self.sections = sections
        self.permissions = permissions
        self.defaults = defaults
        known = defaults.data(forKey: Self.knownKey).flatMap { try? NewItemPlacement.decode($0) }
    }

    func start() {
        observe()
        schedule(after: Self.debounce)
    }

    /// Re-decides (debounced) when the scan results, section state, or permissions change.
    private func observe() {
        withObservationTracking {
            _ = scanner.items
            _ = sections.state
            _ = sections.isEditing
            _ = permissions.allGranted
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
        evaluateTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.evaluate()
        }
    }

    /// Layout is trustworthy: all permissions granted (titles and owners readable), scan OK, collapsed, not editing.
    /// `observe` re-triggers a decision when any of these change.
    private var layoutIsTrustworthy: Bool {
        permissions.allGranted && scanner.status == .ok && sections.state == .collapsed && !sections.isEditing
    }

    private func evaluate() async {
        guard permissions.allGranted else { return }
        if known == nil, !refreshedForSeeding {
            await scanner.refreshOwnership()
            refreshedForSeeding = true
        }
        guard layoutIsTrustworthy, let controls = sections.controlWindows else { return }
        guard !mover.isBusy, NSEvent.pressedMouseButtons == 0 else {
            // Not a good time to move (another move transaction running, mouse held down): check again later.
            schedule(after: Self.retryDelay)
            return
        }
        let layout = SectionAssigner.layout(of: scanner.items, controls: controls)
        guard !layout.isEmpty else { return }
        let firstRun = known == nil && defaults.bool(forKey: Self.firstRunKey)
        let decision = NewItemPlacement.decide(layout: layout, known: known, considered: considered,
                                               firstRun: firstRun)
        considered = decision.considered
        remember(decision.learned, seeding: known == nil)
        defaults.removeObject(forKey: Self.firstRunKey)
        if firstRun, !decision.toMove.isEmpty {
            FrostLog.newItems.notice("first run: moving \(decision.toMove.count) pre-existing items from Always Hidden to Hidden")
        }
        guard !decision.toMove.isEmpty else { return }
        // Move in a task that doesn't inherit cancellation: the rescans during the move change `scanner.items`,
        // which triggers `observe` -> `schedule` and cancels `evaluateTask`. If the move were cancelled with it, these
        // items would be marked as seen and stay in Always Hidden forever.
        // Decisions triggered during the move retry later because of `mover.isBusy`.
        let toMove = decision.toMove
        await Task { @MainActor in await self.move(toMove, controls: controls) }.value
    }

    private func move(_ items: [MenuBarItem], controls: FrostControlWindows) async {
        do {
            try await mover.transaction {
                for item in items {
                    do {
                        try await mover.move(item.windowID, to: .leftOf(controls.hiddenSeparator))
                        FrostLog.newItems.notice("moved new item \(item.identity.bundleID, privacy: .public) out of Always Hidden")
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch ItemMoveError.controlsDisturbed {
                        // Frost's own icons were dragged (routing fell back to position): stop moving the rest.
                        FrostLog.newItems.error("stopped placing new items: Frost's controls were disturbed")
                        break
                    } catch {
                        FrostLog.newItems.error(
                            "failed to move new item \(item.identity.bundleID, privacy: .public) out of Always Hidden: \(error, privacy: .public)")
                    }
                }
            }
        } catch ItemMoveError.busy {
            // Another transaction just started: retry later (these items aren't marked as seen yet).
            schedule(after: Self.retryDelay)
            return
        } catch is CancellationError {
            // Shouldn't happen (see `evaluate`); if cancelled anyway, don't mark as seen and retry later.
            schedule(after: Self.retryDelay)
            return
        } catch {
            FrostLog.newItems.error("placing new items failed: \(error, privacy: .public)")
        }
        considered.formUnion(items.map(\.windowID))
        remember(Set(items.compactMap(NewItemPlacement.identity(of:))), seeding: false)
    }

    private func remember(_ identities: Set<ItemIdentity>, seeding: Bool) {
        guard seeding || !identities.isEmpty else { return }
        let updated = (known ?? []).union(identities)
        guard updated != known else { return }
        known = updated
        do {
            defaults.set(try NewItemPlacement.encode(updated), forKey: Self.knownKey)
        } catch {
            FrostLog.newItems.error("failed to save known items: \(error, privacy: .public)")
        }
    }
}
