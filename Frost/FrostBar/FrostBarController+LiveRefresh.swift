import AppKit
import FrostCore

extension FrostBarController {
    // MARK: - Live refresh

    /// (Re)starts the live refresh loop. `immediately`: the next round ignores the 1 s start-to-start interval (panel
    /// opened, ⌥ toggled, manual refresh) but is still `LiveRefreshPolicy.minimumGap` after the previous round ended.
    ///
    /// Each round (`runLiveCycle`): freeze frame over the changing part of the menu bar -> expand temporarily ->
    /// capture -> collapse -> remove the freeze frame; new captures replace the panel's old ones immediately. Pause
    /// rules: `LiveRefreshPolicy.skipReason`.
    func restartLiveRefresh(immediately: Bool) {
        liveTask?.cancel()
        guard isOpen else { return }
        if immediately { lastCycleStart = nil }
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.delayBeforeNextCycle() else { return }
                if delay > .zero {
                    do { try await Task.sleep(for: delay) } catch { return }
                    // Decide again: the appearance animation may have started later than expected (`present`).
                    continue
                }
                guard let self, self.isOpen, !Task.isCancelled else { return }
                // A round left over from the previous loop is still running (the loop restarted on ⌥ toggle /
                // refresh): wait for it before deciding, or its move transaction counts as "move in flight" and
                // pauses us.
                if let running = self.captureTask {
                    await running.value
                    continue
                }
                if let reason = self.liveRefreshSkipReason() {
                    self.liveStats.skip(reason)
                    do { try await Task.sleep(for: LiveRefreshPolicy.pausedRecheck) } catch { return }
                    continue
                }
                self.liveStats.resume()
                await self.runLiveCycle()
            }
        }
    }

    /// Stops the loop (panel closed). A round in progress ends at its next checkpoint, still collapsing and removing the
    /// freeze frame (`captureWhileExpanded`).
    func stopLiveRefresh() {
        liveTask?.cancel()
        liveTask = nil
        if captureTask != nil {
            FrostLog.frostBar.notice("panel closed during a live refresh cycle; it will collapse and clean up")
        }
        if let summary = liveStats.summary() { FrostLog.frostBar.notice("live refresh: \(summary, privacy: .public)") }
        liveStats = LiveRefreshStats()
    }

    private func delayBeforeNextCycle() -> Duration {
        let now = ContinuousClock.now
        return LiveRefreshPolicy.delayBeforeNextCycle(sinceLastStart: lastCycleStart.map { now - $0 },
                                                      sinceLastEnd: lastCycleEnd.map { now - $0 },
                                                      sincePresented: presentedAt.map { now - $0 })
    }

    /// Whether this round should run (pure logic in `LiveRefreshPolicy.skipReason`).
    private func liveRefreshSkipReason() -> LiveRefreshPolicy.SkipReason? {
        let ids = requestedItems.map(\.windowID)
        let sections = app.sections
        let conditions = LiveRefreshPolicy.Conditions(
            isPanelOpen: isOpen && panel?.isVisible == true,
            hasPermissions: app.permissions.capabilities.canLiveRefresh,
            isActivationInFlight: activationTask != nil,
            isMoveInFlight: app.mover.isBusy,
            isMouseButtonPressed: NSEvent.pressedMouseButtons != 0,
            isMenuOnScreen: ItemClicker.isMenuOnScreen(),
            isForwardedPresentationOnScreen: isLingeringPresentationOnScreen(),
            isEditing: sections.isEditing,
            isCollapsed: sections.state == .collapsed,
            isPointerOverChangingMenuBar: isPointerOverChangingMenuBar(),
            hasCapturableItems: !ids.isEmpty && !retryPolicy.expandable(ids, in: captureContext()).isEmpty)
        return LiveRefreshPolicy.skipReason(conditions)
    }

    /// Whether a running round should end now (panel closed, mouse button pressed, or pointer entered the changing part
    /// of the menu bar).
    private var shouldAbortCycle: Bool {
        LiveRefreshPolicy.shouldAbortCycle(isPanelOpen: isOpen, isMouseButtonPressed: NSEvent.pressedMouseButtons != 0,
                                           isPointerOverChangingMenuBar: isPointerOverChangingMenuBar())
    }

    private func isPointerOverChangingMenuBar() -> Bool {
        let iconWindow = app.sections.iconWindow
        let strips = MenuBarFreezeFrame.menuBarStrips(fallbackHeight: iconWindow?.frame.height ?? 24, iconFrames: [],
                                                      managedDisplayID: managedDisplayID)
        return LiveRefreshPolicy.isPointerInChangingRegion(NSEvent.mouseLocation, strips: strips.map(\.frame),
                                                           iconFrames: frostIconFrames)
    }

    /// The Frost icon's frame on each display (AppKit coordinates): the real window (on the active menu bar) plus
    /// replicas on other displays.
    private var frostIconFrames: [CGRect] {
        let replicas = app.scanner.replicaIconFrames.values.map(ScreenCoordinates.appKitRect(fromCG:))
        return (app.sections.iconWindow.map { [$0.frame] } ?? []) + replicas
    }

    /// The display of the scanned menu bar (the active menu bar).
    var managedDisplayID: CGDirectDisplayID {
        app.scanner.menuBarDisplay?.id ?? CGMainDisplayID()
    }

    private func isLingeringPresentationOnScreen() -> Bool {
        guard !lingeringPresentation.isEmpty else { return false }
        if ItemClicker.onscreenWindowIDs().isDisjoint(with: lingeringPresentation) {
            lingeringPresentation = []
            return false
        }
        return true
    }

    /// Items the panel shows: the Hidden section (plus the Always Hidden section with ⌥).
    var requestedItems: [MenuBarItem] {
        let layout = model.layout
        return layout[.hidden, default: []] + (model.showAlwaysHidden ? layout[.alwaysHidden, default: []] : [])
    }

    /// Runs one round (does nothing if the previous one is still running; the loop waits for it first). The round's
    /// body runs in a task that doesn't inherit cancellation (`captureTask`): when the panel closes and the loop is
    /// cancelled, the round still collapses and removes the freeze frame; click forwarding waits for it (`activate`).
    private func runLiveCycle() async {
        guard captureTask == nil else { return }
        let ids = requestedItems.map(\.windowID)
        let alwaysHiddenIDs = Set(model.layout[.alwaysHidden, default: []].map(\.windowID))
        let target: SectionController.State = model.showAlwaysHidden && ids.contains(where: alwaysHiddenIDs.contains)
            ? .expandedAll : .expanded
        let context = captureContext()
        lastCycleStart = .now
        #if DEBUG
        FrameProbe.note("cycle")
        #endif
        // The end time and `captureTask` are updated in the round's own task: on panel close / ⌥ toggle the loop is
        // cancelled and restarted, so a new loop may be the one waiting for this round.
        let task = Task { @MainActor [weak self] () -> Void in
            await self?.captureWhileExpanded(ids, target: target, context: context)
            self?.lastCycleEnd = .now
            self?.captureTask = nil
        }
        captureTask = task
        await task.value
    }

    /// Context for deciding whether items uncapturable under the notch are worth retrying: the collapsed item order
    /// and the display configuration.
    private func captureContext() -> CaptureRetryPolicy.Context {
        let displays = NSScreen.screens.map { screen in
            CaptureRetryPolicy.Display(
                id: screen.displayID ?? 0, frame: screen.frame, scale: screen.backingScaleFactor)
        }
        return CaptureRetryPolicy.Context(items: app.scanner.items, displays: displays)
    }

    /// Under a freeze frame (`MenuBarFreezeFrame`, covering only the changing part of the menu bar): expand
    /// temporarily -> capture the menu bar strip once and crop out each item -> collapse -> remove the freeze frame, so
    /// the user never sees the menu bar change. No expansion if the freeze frame capture fails. Everything from showing
    /// the freeze frame on is one move transaction (mutually exclusive with click forwarding and editor drags); the
    /// freeze frame's screenshot is taken before it, so a click on a tile meanwhile starts its move at once instead of
    /// waiting for the round (the round then gives up without showing anything). Ends early at a checkpoint when
    /// the panel closes, a mouse button is pressed, or the pointer enters the changing part of the menu bar: no more
    /// capturing, but it always collapses and removes the freeze frame. Items still off screen after expanding (under
    /// the notch) are recorded in `retryPolicy` and keep their cached screenshot or app icon without affecting the
    /// cadence.
    private func captureWhileExpanded(_ ids: [CGWindowID], target: SectionController.State,
                                      context: CaptureRetryPolicy.Context) async {
        let sections = app.sections
        let clock = ContinuousClock()
        let start = clock.now
        var timing = LiveRefreshStats.Timing()
        var captured: Set<CGWindowID>?
        /// Items on screen after expanding (the rest are under the notch / don't fit).
        var onScreen: Set<CGWindowID> = []
        let mover = app.mover
        let transactionsBefore = mover.transactionCount
        guard let screenshot = await MenuBarFreezeFrame.capture(
            menuBarFallbackHeight: sections.iconWindow?.frame.height ?? 24, iconFrames: frostIconFrames,
            managedDisplayID: managedDisplayID, contentCache: app.capturer.contentCache)
        else {
            liveStats.freezeFrameFailed()
            return
        }
        // The screenshot must still show the menu bar as it is: give up if a move ran or started meanwhile (e.g. a click
        // on a tile, which closed the panel) or anything else now pauses live refresh. No suspension point between this
        // check and taking the transaction.
        guard !shouldAbortCycle, !mover.isBusy, mover.transactionCount == transactionsBefore, activationTask == nil,
              sections.state == .collapsed else {
            liveStats.aborted()
            return
        }
        do {
            try await mover.transaction { () async -> Void in
                let freeze = await MenuBarFreezeFrame.show(screenshot)
                let shown = clock.now
                timing.freezeFrame = shown - start
                // Every exit path removes the freeze frame (`MenuBarFreezeFrame.maximumDuration` is a safety net).
                defer {
                    freeze.remove()
                    timing.overlay = clock.now - shown
                }
                guard !shouldAbortCycle else { return }
                // Freeze the panel layout while expanded: positions near the notch aren't reliable, and it keeps
                // icons from jumping (screenshots are shown at their own size, see `ItemImageCapturer.sizes`).
                model.frozenLayout = model.layout
                defer { model.frozenLayout = nil }
                var mark = clock.now
                let (prior, expanded) = await sections.temporarilyExpand(target)
                timing.expand = clock.now - mark
                // Don't capture if the expansion wasn't confirmed (timed out): items may still be off screen and
                // would be wrongly recorded as "uncapturable even when expanded".
                if expanded, !shouldAbortCycle {
                    mark = clock.now
                    let wanted = Set(ids)
                    let targets = app.scanner.items.filter { wanted.contains($0.windowID) && $0.isOnScreen }
                    onScreen = Set(targets.map(\.windowID))
                    captured = targets.isEmpty ? [] : await app.capturer.capture(targets)
                    timing.capture = clock.now - mark
                    timing.perWindow = targets.isEmpty ? 0 : app.capturer.lastPerWindowCount
                }
                mark = clock.now
                // Remove the freeze frame only once the collapse (or the state the user asked for meanwhile) is
                // confirmed: keep polling for as long as the freeze frame may stay up.
                let budget = Self.restoreBudget(sinceFreezeFrameShown: clock.now - shown)
                if await sections.restore(prior, timeout: budget) {
                    try? await Task.sleep(for: MenuBarFreezeFrame.settleDelay)
                } else {
                    FrostLog.frostBar.error("""
                        the menu bar was not confirmed restored within \(budget, privacy: .public); \
                        removing the freeze frame at its time limit
                        """)
                }
                timing.collapse = clock.now - mark
            }
        } catch {
            // `.busy`: another move transaction just started (rare; the pause rules already checked). Retry next round.
            return
        }
        timing.total = clock.now - start
        guard let captured else {
            liveStats.aborted()
            return
        }
        // Only items still off screen after expanding count as uncapturable (items whose capture failed once are
        // simply retried next round).
        retryPolicy.recordAttempt(ids, stillMissing: Set(ids).subtracting(onScreen), in: context)
        liveStats.record(timing, captured: captured.count, of: ids.count)
        if Self.traceCycles || liveStats.cycles == 1 {
            FrostLog.frostBar.notice(
                "live refresh cycle: captured \(captured.count) of \(ids.count) item(s); \(timing.description, privacy: .public)")
        }
    }

    /// How long a round may wait for the menu bar to be restored: until shortly before the freeze frame's safety net
    /// (`MenuBarFreezeFrame.maximumDuration`), leaving time for `settleDelay`; never less than a short minimum.
    static func restoreBudget(sinceFreezeFrameShown elapsed: Duration) -> Duration {
        let remaining = MenuBarFreezeFrame.maximumDuration - elapsed - MenuBarFreezeFrame.settleDelay - restoreMargin
        return max(remaining, minimumRestoreBudget)
    }

    private static let restoreMargin: Duration = .milliseconds(100)
    private static let minimumRestoreBudget: Duration = .milliseconds(300)

    func refresh() {
        guard refreshTask == nil else { return }
        model.isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            self.app.permissions.refresh()
            await self.app.scanner.refreshOwnership()
            self.retryPolicy.reset()
            self.restartLiveRefresh(immediately: true)
            // Let the refresh animation complete at least one full turn.
            try? await Task.sleep(for: .milliseconds(500))
            self.model.isRefreshing = false
            self.refreshTask = nil
        }
    }
}
