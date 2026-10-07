import AppKit
import FrostCore

extension FrostBarController {
    // MARK: - Click forwarding

    /// An icon in the panel was clicked: close the panel, temporarily move the original icon into the Visible section
    /// (right of the Frost icon), click it, and move it back once its menu / popover closes. The whole flow is one move
    /// transaction, mutually exclusive with layout editor moves; if another transaction is running it waits for it (up
    /// to `moverWait`) before giving up on the click.
    ///
    /// The activation hand-off (`ActivationHandOff`) begins synchronously while handling the user's click event: only
    /// then does Frost's cooperative activation count as user intent.
    func activate(_ id: CGWindowID, click: ForwardedClick = .primary) {
        guard activationTask == nil else { return }
        endLingerRequested = false
        forwardTrace = ForwardTrace()
        close(reason: "click forward")
        let handOff = ActivationHandOff.begin(for: app.scanner.items.first { $0.windowID == id })
        forwardTrace?.mark("closed")
        activationTask = Task { [weak self] in
            guard let self else {
                handOff?.finish()
                return
            }
            self.forwardTrace?.mark("started")
            // A live refresh round holds the move transaction (temporary expansion): wait for it to collapse and
            // remove its freeze frame before moving. A round still taking its freeze-frame screenshot doesn't hold it
            // and gives up once it sees this click (`captureWhileExpanded`): no need to wait for it.
            if let capture = self.captureTask, self.app.mover.isBusy {
                FrostLog.frostBar.notice("activation waits for the live refresh cycle to restore the collapsed state")
                await capture.value
                self.forwardTrace?.mark("liveRefreshDone")
            }
            // The previous move-back failed and awaits a retry: retry now, or it would stay in the Visible section
            // after this move.
            await self.flushRestoreRetry()
            await self.forward(id, click: click, handOff: handOff)
            // On error (e.g. the move out failed) `clickAndWait` may not have run: make sure activation is handed back.
            handOff?.finish()
            self.forwardTrace = nil
            self.activationTask = nil
        }
    }

    /// How long a click forward waits for another move transaction to finish before it is dropped.
    private static let moverWait: Duration = .seconds(2)

    /// The current (or most recent) click forwarding task; tests and reopening the panel wait for it.
    var pendingActivation: Task<Void, Never>? { activationTask }

    /// Whether a click forward, capture round, background capture or move-back retry is still pending (quitting must
    /// wait for them, or a moved-out icon would stay in the Visible section).
    var hasPendingWork: Bool {
        activationTask != nil || captureTask != nil || restoreRetryTask != nil || obscuredCaptureTask != nil
    }

    /// Called before quitting: cancels a click forward waiting for its menu to close (it still moves back after
    /// cancellation; the menu wait has no limit, so this is the only way to end it), runs any pending move-back retry
    /// right away, and waits for both.
    func prepareForTermination() async {
        close(animated: false, reason: "quitting")
        if let activation = activationTask {
            activation.cancel()
            await activation.value
        }
        if let capture = captureTask { await capture.value }
        // A background capture sees the shutdown at its next checkpoint and moves its item back right away.
        obscuredLoop?.cancel()
        if let obscured = obscuredCaptureTask { await obscured.value }
        await flushRestoreRetry()
    }

    /// If a move-back retry is pending: skip the remaining delay, run it now, and wait for it.
    func flushRestoreRetry() async {
        guard let retry = restoreRetryTask else { return }
        retry.cancel()
        await retry.value
    }

    private func forward(_ id: CGWindowID, click: ForwardedClick, handOff: ActivationHandOff?) async {
        let mover = app.mover
        // Another transaction (an editor drop, a new-item placement) holds the mover: wait for it (bounded) instead of
        // silently dropping the user's click. No suspension point between the wait and `transaction`, so nothing can
        // slip in once it is idle.
        if mover.isBusy {
            FrostLog.frostBar.notice("activation waits for another move to finish")
            guard await mover.waitUntilIdle(timeout: Self.moverWait), !Task.isCancelled else {
                FrostLog.frostBar.error("activate dropped: another move was still in progress after \(Self.moverWait, privacy: .public)")
                return
            }
        }
        do {
            try await mover.transaction { try await self.moveOutClickAndRestore(id, click: click, handOff: handOff) }
        } catch ItemMoveError.busy {
            FrostLog.frostBar.notice("activate ignored: another move is in progress")
        } catch ItemMoveError.shuttingDown {
            FrostLog.frostBar.notice("activate ignored: Frost is quitting")
        } catch is CancellationError {
            // Only `prepareForTermination` cancels a forward; the icon has been moved back by now.
            FrostLog.frostBar.notice("activate ended early: Frost is quitting")
        } catch {
            FrostLog.frostBar.error("activate failed: \(error, privacy: .public)")
        }
    }

    private func moveOutClickAndRestore(_ id: CGWindowID, click: ForwardedClick,
                                        handOff: ActivationHandOff?) async throws {
        let sections = app.sections, scanner = app.scanner, mover = app.mover
        forwardTrace?.mark("transaction")
        guard !sections.isEditing else { throw FrostBarError.editing }
        if sections.state != .collapsed {
            sections.setState(.collapsed)
            await sections.waitForSettle()
        }
        scanner.rescan()
        // With an unknown owner only menus (layer 101) can be detected, not popovers (layer 25, matched by owner): after
        // 1 s of "nothing opened" the icon would be moved back while its popover is open. Force an ownership read first.
        if scanner.items.first(where: { $0.windowID == id })?.pid == nil {
            await scanner.refreshOwnership()
            if scanner.items.first(where: { $0.windowID == id })?.pid == nil {
                FrostLog.frostBar.notice("owner of item \(id) is unknown; only menus (not popovers) will be detected")
            }
        }
        guard let controls = sections.controlWindows else { throw FrostBarError.controlsMissing }
        let layout = SectionAssigner.layout(of: scanner.items, controls: controls)
        guard let plan = RestorePlan.make(for: id, in: layout, controls: controls) else {
            // Already in the Visible section (e.g. the user just moved it there): just click it.
            guard layout[.visible, default: []].contains(where: { $0.windowID == id }) else {
                throw FrostBarError.itemNotFound
            }
            try await clickAndWait(id, click: click, strayBaseline: nil, handOff: handOff)
            return
        }

        var failure: Error?
        // The item lingered until the user was done with it: its presentation is closed, so an open menu is someone
        // else's (the user may just have clicked another menu bar item), which the move back waits for.
        var lingered = false
        // Window snapshot before the move, to detect a menu accidentally opened by the ⌘-drag (see `clickAndWait`).
        let beforeMove = ItemClicker.onscreenWindowIDs()
        do {
            forwardTrace?.mark("moveStart")
            // Click as soon as the item has reached its final frame (the windows left of it may still be sliding, which
            // doesn't move it or its menu; see `LandingDetector`). The pointer stays hidden during the ⌘-drag and then
            // appears on the item: it visibly moves once, from the tile to the menu bar, and stays there.
            try await mover.move(id, to: .rightOf(controls.icon), until: .itemLanded, cursor: .onMovedItem)
            forwardTrace?.mark("moved")
            let outcome = try await clickAndWait(id, click: click, strayBaseline: beforeMove, handOff: handOff)
            // A presentation still on screen (timed out / abandoned) isn't the user's to keep using: move back now.
            if outcome == .closed || outcome == .notPresented {
                try await linger(id)
                lingered = true
            }
        } catch {
            failure = error
        }
        // Move back: success, failure, and cancellation share this path. It runs in a task that doesn't inherit
        // cancellation so it still happens when cancelled. If the move out never took effect, `move` finds the item
        // already in place and returns.
        let cancelled = failure is CancellationError
        // The Frost Bar is opening (it ended the linger): place it under the Frost icon's final position and let it
        // appear as soon as the item has been dropped, not after the ~0.4 s slide of the icons
        // (`LingerReturnAnchor`).
        let opening = endLingerRequested && isOpen && !cancelled
        if opening { predictReturnAnchor(of: id, controls: controls) }
        let completion: ItemMover.Completion = returnAnchorMaxX != nil ? .itemLanded : .settled
        let restoreError = await Task { @MainActor in
            if cancelled { await self.closePresentation(of: id, openedAfter: beforeMove) }
            return await self.restore(plan, controls: controls, until: completion,
                                      yieldingToMenus: lingered && !opening && completion == .settled)
        }.value
        if let restoreError {
            if case ItemMoveError.controlsDisturbed = restoreError {
                // Routing fell back to position and dragged the Frost icon; retrying would just drag it again.
                FrostLog.frostBar.error("restore failed: Frost's controls were disturbed; not retrying")
            } else {
                FrostLog.frostBar.error("restore failed: \(restoreError, privacy: .public); retrying in 1.5 s")
                scheduleRestoreRetry(plan, controls: controls)
            }
        }
        if let failure { throw failure }
    }

    /// Records where the Frost icon will be once the lingering item `id` (its right-hand neighbor) has moved back, for
    /// the opening Frost Bar's placement (`returnAnchorMaxX`); leaves it nil when that can't be predicted.
    private func predictReturnAnchor(of id: CGWindowID, controls: FrostControlWindows) {
        let windows = StatusWindowParser.windows(withIDs: [controls.icon, id])
        guard let icon = windows.first(where: { $0.windowID == controls.icon }), icon.isOnScreen,
              let item = windows.first(where: { $0.windowID == id }), item.isOnScreen else { return }
        returnAnchorMaxX = LingerReturnAnchor.iconMaxX(icon: icon.frame, item: item.frame)
    }

    /// Moves the item back to its original section. If the anchor destination fails (anchor gone, move didn't take
    /// effect, under the notch... any error except disturbed Frost control items), tries the section boundary once, and
    /// from there one corrective move into its slot (`RestorePlan.correction`) if its anchor is still in the section.
    /// A vanished item (its app quit) counts as success.
    func restore(_ plan: RestorePlan, controls: FrostControlWindows,
                 until completion: ItemMover.Completion = .settled, yieldingToMenus: Bool = false) async -> Error? {
        let scanner = app.scanner, mover = app.mover
        scanner.rescan()
        let destination = plan.destination(in: SectionAssigner.layout(of: scanner.items, controls: controls))
        do {
            try await mover.move(plan.itemID, to: destination, until: completion, yieldingToMenus: yieldingToMenus)
            return nil
        } catch ItemMoveError.itemNotFound {
            // The app quit: nothing to move back.
            return nil
        } catch ItemMoveError.controlsDisturbed {
            // Another move would just drag the Frost icon again (`ItemMover` already tried to put it back).
            return ItemMoveError.controlsDisturbed
        } catch {
            guard destination != plan.boundary else { return error }
            FrostLog.frostBar.error("""
                restore to \(String(describing: destination), privacy: .public) failed \
                (\(error, privacy: .public)); falling back to the section boundary
                """)
            do {
                try await mover.move(plan.itemID, to: plan.boundary, yieldingToMenus: yieldingToMenus)
            } catch ItemMoveError.itemNotFound {
                return nil
            } catch {
                return error
            }
            // Back in its section, but at the edge: put it into its slot if that is possible again now.
            await correctSlot(plan, controls: controls, yieldingToMenus: yieldingToMenus)
            return nil
        }
    }

    /// One corrective move when the item isn't in its slot (`RestorePlan.correction`), e.g. left at its section's edge
    /// by a fallback. If it fails, the item stays where it is (in its section).
    private func correctSlot(_ plan: RestorePlan, controls: FrostControlWindows, yieldingToMenus: Bool) async {
        let scanner = app.scanner
        scanner.rescan()
        guard let correction = plan.correction(in: SectionAssigner.layout(of: scanner.items, controls: controls))
        else { return }
        FrostLog.frostBar.notice("""
            item \(plan.itemID, privacy: .public) is not back in its slot; moving it \
            \(String(describing: correction), privacy: .public)
            """)
        do {
            try await app.mover.move(plan.itemID, to: correction, yieldingToMenus: yieldingToMenus)
        } catch {
            FrostLog.frostBar.error("""
                moving item \(plan.itemID, privacy: .public) into its slot failed (\(error, privacy: .public)); \
                it stays at its section's edge
                """)
        }
    }

    /// After a failed move-back, tries once more in a new move transaction after `restoreRetryDelay` (e.g. occasional
    /// failures caused by drag remnants succeed on a later retry). Cancelling the task (quit, next click forward) skips
    /// the remaining delay and retries immediately.
    func scheduleRestoreRetry(_ plan: RestorePlan, controls: FrostControlWindows) {
        restoreRetryTask?.cancel()
        restoreRetryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.restoreRetryDelay)
            // The retry itself runs in a task that doesn't inherit cancellation; cancelling only skips the delay.
            await Task { @MainActor [weak self] in await self?.retryRestore(plan, controls: controls) }.value
            self?.restoreRetryTask = nil
        }
    }

    private func retryRestore(_ plan: RestorePlan, controls: FrostControlWindows) async {
        let mover = app.mover, sections = app.sections
        // Wait up to 5 s for a running transaction (editor drag etc.) to finish.
        _ = await mover.waitUntilIdle(timeout: .seconds(5))
        do {
            // Putting the icon back is exactly what quitting waits for, so it may run while shutting down.
            try await mover.transaction(allowedDuringShutdown: true) {
                if sections.isEditing {
                    // While editing, positions may be under the notch and unreliable: collapse temporarily to move.
                    try await sections.whileCollapsedForMove {
                        try await self.restoreIfNeeded(plan, controls: controls, yieldingToMenus: true)
                    }
                } else {
                    if sections.state != .collapsed {
                        sections.setState(.collapsed)
                        await sections.waitForSettle()
                    }
                    try await restoreIfNeeded(plan, controls: controls, yieldingToMenus: true)
                }
            }
            FrostLog.frostBar.notice("delayed restore succeeded")
        } catch {
            FrostLog.frostBar.error("delayed restore failed: \(error, privacy: .public)")
        }
    }

    /// Moves the item back if it isn't in its slot (still outside its original section, or in it but elsewhere, e.g. at
    /// its edge after a fallback); does nothing if it's back or gone.
    /// `yieldingToMenus`: see `ItemMover.move` (not under a freeze frame, which hides menus).
    func restoreIfNeeded(_ plan: RestorePlan, controls: FrostControlWindows, yieldingToMenus: Bool = false) async throws {
        let scanner = app.scanner
        scanner.rescan()
        let controls = app.sections.controlWindows ?? controls
        guard plan.correction(in: SectionAssigner.layout(of: scanner.items, controls: controls)) != nil else { return }
        if let error = await restore(plan, controls: controls, yieldingToMenus: yieldingToMenus) { throw error }
    }

    /// Clicks the item once its frame is stable and waits for its menu / popover to close (returns right away if
    /// nothing opens within 1 s). Menus have no wait limit (they always close when the user clicks elsewhere);
    /// popovers / panels wait up to 60 s (some don't close on an outside click), see `ItemClicker.closeWaitLimit`.
    /// When Frost quits, `prepareForTermination` cancels the wait and the item is moved back as usual.
    ///
    /// Activation hand-off: when a non-menu presentation is detected, activation goes to that app
    /// (`handOff.activateTarget()`; menus are not handed off, see `ActivationHandOff`), and after the wait it's handed
    /// back if Frost is still frontmost (`handOff.finish()`). While waiting, `OutsideClickFallback` handles non-menu
    /// presentations that don't close on an outside click: Esc -> click the item again -> give up waiting.
    ///
    /// The ⌘-drag's mouse-down occasionally makes the moved item open its menu (seen on real hardware, at its pre-move
    /// position with hidden items off screen); clicking again would just close it and the user would see nothing. So
    /// before clicking, check whether the item's app opened new windows during the move (after `strayBaseline`): if
    /// so, close them with a mouse click first (AXPress doesn't work during menu tracking), wait for them to go, then
    /// click normally. Skipped when the owner is unknown. `strayBaseline` holds only the on-screen windows before the
    /// move; `ItemClicker.newWindows` excludes all status bar windows (the moved item's own window was off screen
    /// before the move; Control Center's own items are owned by Control Center) and drag remnants at layer >= 500.
    @discardableResult
    private func clickAndWait(_ id: CGWindowID, click: ForwardedClick, strayBaseline: Set<CGWindowID>?,
                              handOff: ActivationHandOff?) async throws -> PresentationOutcome {
        defer { handOff?.finish() }
        let item = try await settledOnScreenItem(id)
        forwardTrace?.mark("onScreen")
        if let strayBaseline, let pid = item.pid,
           !ItemClicker.newWindows(ownedBy: pid, excluding: strayBaseline).isEmpty {
            FrostLog.frostBar.notice("a presentation opened during the move; dismissing it before clicking")
            try await ItemClicker.click(item, forceEvent: true)
            try await waitUntilDismissed(pid: pid, baseline: strayBaseline)
        }
        let baseline = ItemClicker.onscreenWindowIDs()
        let fallback = OutsideClickFallback(item: item, baseline: baseline)
        // Every exit path (closed, abandoned, timed out, cancelled, error) removes the mouse monitors.
        defer { fallback?.stop() }
        // The pointer rests on the item from now on (the move out usually put it there already): it doesn't jump back
        // to the tile, and it keeps the linger going until the user moves away.
        if let point = CursorPlacement.restingPoint(forClickOn: item.frame, cursor: CGEvent(source: nil)?.location) {
            CGWarpMouseCursorPosition(point)
        }
        forwardTrace?.mark("click")
        try await ItemClicker.click(item, kind: click)
        forwardTrace?.mark("clicked")
        if let trace = forwardTrace {
            FrostLog.frostBar.notice("""
                click forward (\(click.logName, privacy: .public)) of \(id, privacy: .public): \
                \(trace.description, privacy: .public)
                """)
            forwardTrace = nil
        }
        lingeringPresentation = []
        let hooks = Self.nonMenuHooks(fallback: fallback, handOff: handOff) { [weak self] windows in
            await self?.recordPresentation(windows)
        }
        let outcome = try await ItemClicker.waitForPresentationToClose(baseline: baseline, ownerPID: item.pid,
                                                                       nonMenuHooks: hooks)
        if outcome == .timedOut || outcome == .abandoned {
            // The presentation may still be on screen: Frost Bar live refresh pauses until it's gone
            // (`LiveRefreshPolicy`).
            FrostLog.frostBar.notice("presentation of item \(id): \(String(describing: outcome), privacy: .public); restoring the icon")
        } else {
            lingeringPresentation = []
        }
        fallback?.stop()
        // The presentation is over: hand activation back early (no need to wait for the move back).
        handOff?.finish()
        // Warm the screenshot cache while we're here: the item is in the Visible section with its menu closed (no
        // pressed highlight); once back in the Hidden section it can't be captured. Skipped when the Frost Bar is
        // waiting to open (it ends the linger at once; its live refresh captures the item anyway).
        if app.permissions.screenRecording, !endLingerRequested {
            app.scanner.rescan()
            if let fresh = app.scanner.items.first(where: { $0.windowID == id && $0.isOnScreen }) {
                await app.capturer.capture([fresh])
            }
        }
        return outcome
    }

    // MARK: - Linger

    /// After the forwarded click's presentation closed, keeps the item in the Visible section while the user is still
    /// using it there (pointer on it, clicking it again for its other menu), so a follow-up click doesn't hit an
    /// empty slot, and moves it back shortly after that so the Frost icon returns to where the user expects it. Decisions: `ForwardLinger`; this polls every 100 ms. Ends at once when the Frost Bar reopens or the
    /// layout editor opens; while the user is away it pauses (no moves). Quitting cancels the task (the sleep throws),
    /// and the caller closes any open presentation and moves the item back as usual.
    private func linger(_ id: CGWindowID) async throws {
        let pid = app.scanner.items.first { $0.windowID == id }?.pid
        var state = ForwardLinger(start: .now)
        var baseline = ItemClicker.onscreenWindowIDs()
        let watcher = ItemClickWatcher()
        defer { watcher.stop() }
        while true {
            if endLingerRequested || app.sections.isEditing {
                FrostLog.frostBar.notice("linger of item \(id, privacy: .public) ended early; moving it back")
                return
            }
            try await Task.sleep(for: Self.lingerPoll)
            // The app quit (item gone): nothing to keep out.
            guard let window = StatusWindowParser.windows(withIDs: [id]).first, window.isOnScreen else { return }
            watcher.frame = window.frame
            if app.presence.isAway { continue }
            let presentation = ItemClicker.presentation(excluding: baseline, ownerPID: pid)
            let sample = ForwardLinger.Sample(
                time: .now, isPointerOverItem: ForwardLinger.pointerRegion(of: window.frame).contains(Self.cgPointer()),
                isMouseButtonHeld: UserMouseButtons.isAnyHeld, clickedItem: watcher.consumeClick(),
                isPresentationOpen: !presentation.windows.isEmpty, isMenuOpen: presentation.containsMenu)
            if case .restore(let reason) = state.update(sample) {
                FrostLog.frostBar.debug("""
                    linger end: pointer \(String(describing: Self.cgPointer()), privacy: .public), \
                    item \(String(describing: window.frame), privacy: .public)
                    """)
                FrostLog.frostBar.notice("""
                    linger of item \(id, privacy: .public) over (\(reason.rawValue, privacy: .public)); moving it back
                    """)
                return
            }
            if state.acceptsNewBaseline, presentation.windows.isEmpty { baseline = ItemClicker.onscreenWindowIDs() }
        }
    }

    private static let lingerPoll: Duration = .milliseconds(100)

    /// The pointer in CG global coordinates (top-left origin).
    private static func cgPointer() -> CGPoint {
        ScreenCoordinates.cgPoint(fromAppKit: NSEvent.mouseLocation)
    }

    private func recordPresentation(_ windows: Set<CGWindowID>) {
        lingeringPresentation = windows
    }

    /// When a non-menu presentation appears: record its windows (`record`), hand activation to its app, then install
    /// the outside-click fallback monitors.
    private static func nonMenuHooks(fallback: OutsideClickFallback?, handOff: ActivationHandOff?,
                                     record: @escaping @Sendable (Set<CGWindowID>) async -> Void)
        -> NonMenuPresentationHooks {
        let fallbackHooks = fallback?.hooks
        return NonMenuPresentationHooks(
            presented: { windows in
                await record(windows)
                await handOff?.activateTarget()
                await fallbackHooks?.presented(windows)
            },
            poll: { isFading in await fallbackHooks?.poll(isFading) ?? false })
    }

    /// Quitting cancels the wait for a forwarded click's menu / popover while it may still be open. An open menu
    /// consumes the ⌘-drag's mouse-down, so the move back would fail (and while quitting, a failed move isn't retried
    /// and the item lands at the section boundary instead of its old place): close it first with a click on the item,
    /// as a user would.
    private func closePresentation(of id: CGWindowID, openedAfter baseline: Set<CGWindowID>) async {
        guard let pid = app.scanner.items.first(where: { $0.windowID == id })?.pid,
              !ItemClicker.newWindows(ownedBy: pid, excluding: baseline).isEmpty else { return }
        FrostLog.frostBar.notice("closing the presentation of item \(id) before moving it back")
        do {
            let item = try await settledOnScreenItem(id)
            try await ItemClicker.click(item, forceEvent: true)
            try await waitUntilDismissed(pid: pid, baseline: baseline)
        } catch {
            FrostLog.frostBar.error("closing the presentation of item \(id) failed: \(error, privacy: .public)")
        }
    }

    /// Waits until all of the app's windows outside `baseline` are gone (up to 1 s; a closed menu's window disappears
    /// in ~0.25 s, a popover's in ~0.5 s).
    private func waitUntilDismissed(pid: pid_t, baseline: Set<CGWindowID>) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while clock.now < deadline, !ItemClicker.newWindows(ownedBy: pid, excluding: baseline).isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// After moving out, confirms the item's frame is stable and on screen: the click must land at the final position,
    /// or the menu opens mid-animation. `ItemMover.move` already waited for the item to land in its final frame
    /// (`LandingDetector`) and rescanned; this double-checks via CGWindowList every 10 ms until 2 identical on-screen reads
    /// (the first compared with the scanned frame), up to 1.5 s.
    func settledOnScreenItem(_ id: CGWindowID) async throws -> MenuBarItem {
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(1500)
        var previous = app.scanner.items.first { $0.windowID == id && $0.isOnScreen }?.frame
        while clock.now < deadline {
            guard let window = StatusWindowParser.windows(withIDs: [id]).first
            else { throw FrostBarError.itemNotFound }
            if window.isOnScreen, window.frame == previous { break }
            previous = window.isOnScreen ? window.frame : nil
            try await Task.sleep(for: .milliseconds(10))
        }
        app.scanner.rescan()
        guard let item = app.scanner.items.first(where: { $0.windowID == id }) else { throw FrostBarError.itemNotFound }
        guard item.isOnScreen else { throw FrostBarError.notOnScreen }
        return item
    }
}

/// Watches for the user's mouse-downs (left or right) on a lingering item's frame (global monitor: the item belongs to
/// another app; local monitor: in case Frost is frontmost). Frost's own synthetic events are ignored.
@MainActor
private final class ItemClickWatcher {
    /// The item's current frame (CG global coordinates); nil = not known yet.
    var frame: CGRect?
    private var clicked = false
    private var monitors = EventMonitors()

    init() {
        monitors.add(matching: [.leftMouseDown, .rightMouseDown], global: { [weak self] event in self?.mouseDown(event) })
    }

    /// Whether the item was clicked since the last call.
    func consumeClick() -> Bool {
        defer { clicked = false }
        return clicked
    }

    func stop() {
        monitors.removeAll()
    }

    private func mouseDown(_ event: NSEvent) {
        guard !SyntheticEvents.isPostedByFrost(event), let frame else { return }
        // The event's own location (the pointer may have moved on by now).
        let point = ScreenCoordinates.cgPoint(fromAppKit: event.screenLocation)
        if frame.contains(point) { clicked = true }
    }
}
