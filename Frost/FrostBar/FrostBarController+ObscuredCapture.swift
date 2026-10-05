import AppKit
import FrostCore

/// A click the background capture's freeze frame took instead of the menu bar (see `captureObscuredItem`).
struct InterceptedClick {
    /// AppKit global coordinates.
    var location: NSPoint
    /// A right click or a Control click (the Frost icon's menu).
    var isContextClick: Bool
    var option: Bool
}

extension FrostBarController {
    // MARK: - Background capture of items behind the notch

    /// (Re)starts the loop that captures items behind the notch in the background (`ObscuredCapturePolicy`): called
    /// when an expanded scan finds new ones or known ones without a current capture, when the captures become invalid
    /// (an appearance change; `ObscuredCapturePolicy.shouldWake`), and on a manual refresh. Runs only
    /// while something is due (an item without a capture, or one whose capture may be out of date), checking every
    /// `ObscuredCapturePolicy.recheck` whether the menu bar is free; ends when nothing is due. One item per operation.
    func scheduleObscuredCapture() {
        obscuredLoop?.cancel()
        obscuredLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let running = self.obscuredCaptureTask {
                    await running.value
                    continue
                }
                guard let wait = self.obscuredCaptureWait() else {
                    self.obscuredLoop = nil
                    return
                }
                if wait > .zero {
                    do { try await Task.sleep(for: wait) } catch { return }
                    continue
                }
                let task = Task { @MainActor [weak self] () -> Void in
                    await self?.captureObscuredItem()
                    self?.obscuredCaptureTask = nil
                }
                self.obscuredCaptureTask = task
                await task.value
            }
        }
    }

    /// How long the loop waits before its next decision: zero when an operation may start now, nil when nothing is
    /// due. Logs the reason it waits whenever it changes.
    private func obscuredCaptureWait() -> Duration? {
        // Without Screen Recording nothing can be captured (and granting it takes a relaunch): stop.
        guard app.permissions.canCaptureImages else { return nil }
        let now = ContinuousClock.now
        let items = app.scanner.items
        app.obscuredCapture.retain(Set(items.map(\.windowID)))
        let obscured = app.obscuredCapture.obscuredItems
        guard !obscured.isEmpty else { return nil }
        let candidates = items.filter { obscured.contains($0.windowID) }
        let needing = Set(app.capturer.missing(candidates).map(\.windowID))
        guard let due = app.obscuredCapture.timeUntilNextDue(order: candidates.map(\.windowID),
                                                            needsImage: needing.contains, now: now)
        else { return nil }
        guard due <= .zero else {
            noteObscuredSkip(nil)
            return due
        }
        let reason = app.obscuredCapture.skipReason(obscuredConditions(), now: now)
        noteObscuredSkip(reason)
        guard let reason else { return .zero }
        switch reason {
        case .permissionsMissing, .away, .frostBarOpen, .editing, .notCollapsed:
            return ObscuredCapturePolicy.recheck * 5
        default:
            return ObscuredCapturePolicy.recheck
        }
    }

    private func noteObscuredSkip(_ reason: ObscuredCapturePolicy.SkipReason?) {
        guard reason != lastObscuredSkip else { return }
        lastObscuredSkip = reason
        if let reason, reason != .spacing {
            FrostLog.capture.info("background capture waits (\(reason.rawValue, privacy: .public))")
        }
    }

    /// The current conditions (`ObscuredCapturePolicy.Conditions`).
    private func obscuredConditions() -> ObscuredCapturePolicy.Conditions {
        let sections = app.sections
        // The user's own input (HID state; `kCGAnyInputEventType` isn't a `CGEventType` case, so the kinds that matter).
        let idle = Self.userInputKinds.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .min() ?? .infinity
        return ObscuredCapturePolicy.Conditions(
            // Moving needs Accessibility, capturing Screen Recording: without it the feature is off.
            hasPermissions: app.permissions.capabilities.canLiveRefresh,
            isUserAway: app.presence.isAway, isShuttingDown: app.mover.isShuttingDown, isFrostBarOpen: isOpen,
            isFrostBarBusy: activationTask != nil || captureTask != nil || restoreRetryTask != nil,
            isEditing: sections.isEditing, isCollapsed: sections.state == .collapsed,
            isMoveInFlight: app.mover.isBusy, isPlacingItems: !app.newItems.isIdle,
            isMouseButtonHeld: UserMouseButtons.isAnyHeld, isMenuOnScreen: ItemClicker.isMenuOnScreen(),
            isPointerInMenuBar: isPointerInAnyMenuBar(),
            sinceLastInput: idle.isFinite ? .milliseconds(Int(idle * 1000)) : nil)
    }

    private static let userInputKinds: [CGEventType] = [
        .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .rightMouseDragged,
        .scrollWheel, .keyDown, .flagsChanged,
    ]

    /// Whether the pointer is over any display's menu bar.
    private func isPointerInAnyMenuBar() -> Bool {
        let pointer = NSEvent.mouseLocation
        let strips = MenuBarFreezeFrame.menuBarStrips(fallbackHeight: app.sections.iconWindow?.frame.height ?? 24,
                                                      iconFrames: [], managedDisplayID: managedDisplayID)
        return strips.contains { strip in
            pointer.x >= strip.frame.minX && pointer.x < strip.frame.maxX
                && pointer.y >= strip.frame.minY && pointer.y <= strip.frame.maxY
        }
    }

    /// Whether the operation in progress must stop now: the user (or Frost) needs the menu bar.
    private var shouldAbortObscuredCapture: Bool {
        interceptedClick != nil || ObscuredCapturePolicy.shouldAbort(obscuredConditions())
    }

    /// One operation: captures the next due item behind the notch by moving it out.
    ///
    /// Under a freeze frame of every menu bar (`MenuBarFreezeFrame`, `.wholeMenuBar`; its screenshot is taken before the
    /// move transaction, so a click forward or a drop meanwhile makes the operation give up without showing anything):
    /// move the item right of the Frost icon (pointer hidden and put back, `CursorDisposition.restore`) -> wait until it
    /// has landed on screen -> capture it (the strip capture, memory + disk cache) -> move it back to its exact slot
    /// (`RestorePlan`: next to its old neighbor, else the section boundary) and wait until every window has settled ->
    /// remove the freeze frame. At every checkpoint it stops early when the user (or Frost) needs the menu bar
    /// (`ObscuredCapturePolicy.shouldAbort`, or a click the freeze frame took): no capture, the item goes back at once.
    /// A click taken on the Frost icon is replayed afterwards (it opens the Frost Bar as usual); any other click is
    /// dropped (it would have hit an item that had shifted under the pointer).
    private func captureObscuredItem() async {
        let app = app, sections = app.sections, scanner = app.scanner, mover = app.mover
        let clock = ContinuousClock()
        let start = clock.now
        scanner.rescan()
        let obscured = app.obscuredCapture.obscuredItems
        let candidates = scanner.items.filter { obscured.contains($0.windowID) }
        let needing = Set(app.capturer.missing(candidates).map(\.windowID))
        guard let next = app.obscuredCapture.nextItem(order: candidates.map(\.windowID), needsImage: needing.contains,
                                                      now: .now),
              app.obscuredCapture.skipReason(obscuredConditions(), now: .now) == nil,
              let controls = sections.controlWindows else { return }
        let id = next.id
        let before = SectionAssigner.layout(of: scanner.items, controls: controls)
        guard let plan = RestorePlan.make(for: id, in: before, controls: controls) else {
            // Not in a hidden section any more (the user moved it into the Visible section): ordinary captures do it.
            app.obscuredCapture.record(.notApplicable, for: id, now: .now)
            return
        }
        // Whether the new capture is compared with a current one, to learn whether the image changes (not a missing
        // image, nor a capture from another appearance).
        let hadPrevious = !needing.contains(id) && app.capturer.images[id] != nil
        let transactionsBefore = mover.transactionCount
        interceptedClick = nil
        guard let screenshot = await MenuBarFreezeFrame.capture(
            menuBarFallbackHeight: sections.iconWindow?.frame.height ?? 24, iconFrames: frostIconFrames,
            managedDisplayID: managedDisplayID, contentCache: app.capturer.contentCache, coverage: .wholeMenuBar)
        else {
            FrostLog.capture.error("background capture of item \(id, privacy: .public): no freeze frame; not moving it")
            app.obscuredCapture.record(.failed, for: id, now: .now)
            return
        }
        // The screenshot must still show the menu bar as it is (no suspension point between this and the transaction).
        guard !shouldAbortObscuredCapture, !mover.isBusy, mover.transactionCount == transactionsBefore,
              sections.state == .collapsed, !sections.isEditing else {
            app.obscuredCapture.record(.interrupted, for: id, now: .now)
            return
        }
        var timing = ObscuredCaptureTiming()
        timing.screenshot = clock.now - start
        var outcome: ObscuredCapturePolicy.Outcome = .interrupted
        var restoredExactly = false
        var returnIdentity: ItemIdentity?
        do {
            try await mover.transaction { () async -> Void in
                var mark = clock.now
                // Above the ⌘-drags' drag images (the lifted item is drawn at the Frost icon while the button is down).
                let freeze = await MenuBarFreezeFrame.show(
                    screenshot, limit: Self.obscuredFreezeLimit, level: MenuBarFreezeFrame.aboveDragImagesLevel
                ) { [weak self] event in
                    self?.freezeFrameTookClick(event)
                }
                timing.freezeFrame = clock.now - mark
                let shown = clock.now
                defer {
                    freeze.remove()
                    timing.overlay = clock.now - shown
                }
                var attempt: ObscuredCapturePolicy.CaptureAttempt = .notAttempted
                var moveFailed = false
                if !shouldAbortObscuredCapture {
                    do {
                        // If Frost quits before the item is back, the next launch moves it back.
                        returnIdentity = scanner.items.first { $0.windowID == id }
                            .flatMap { app.newItems.notePendingReturn(of: $0, to: plan.section) }
                        mark = clock.now
                        try await moveOutUnlessInterrupted(id, controls: controls)
                        timing.moveOut = clock.now - mark
                        mark = clock.now
                        let item = try await settledOnScreenItem(id)
                        timing.landed = clock.now - mark
                        if !shouldAbortObscuredCapture {
                            mark = clock.now
                            // This round's own result: a failed capture keeps the previous image in the cache.
                            let report = await app.capturer.captureReporting([item])
                            timing.capture = clock.now - mark
                            attempt = report.discarded ? .discarded
                                : report.succeeded(id) ? .succeeded(changed: report.changed.contains(id)) : .failed
                        }
                    } catch is CancellationError {
                        // Interrupted by the user (`moveOutUnlessInterrupted`): not a failure.
                    } catch {
                        FrostLog.capture.error("background capture of item \(id, privacy: .public): moving it out failed (\(error, privacy: .public))")
                        moveFailed = true
                    }
                }
                // Move back (also when the move out failed: `move` finds the item in place and returns), always under
                // the freeze frame (`ObscuredCapturePolicy.RestoreStep`). Waits until every window has stopped sliding,
                // then a frame or two for the menu bar to redraw before the freeze frame goes.
                #if DEBUG
                if let pause = Self.testRestorePause { try? await Task.sleep(for: pause) }
                #endif
                mark = clock.now
                let back = await moveBackUnderFreezeFrame(plan, controls: controls, freeze: freeze)
                timing.moveBack = clock.now - mark
                switch back {
                case .restored:
                    break
                case .handedOff:
                    moveFailed = true
                    FrostLog.capture.error("background capture of item \(id, privacy: .public): a mouse button is still held; moving it back once released, under a new freeze frame")
                    scheduleCoveredRestore(plan, controls: controls, returnIdentity: returnIdentity)
                case .leftForNextLaunch:
                    moveFailed = true
                    FrostLog.capture.error("background capture of item \(id, privacy: .public): Frost is quitting while a mouse button is held; the next launch moves it back")
                case .failed(let restoreError):
                    moveFailed = true
                    if case ItemMoveError.controlsDisturbed = restoreError {
                        FrostLog.capture.error("background capture of item \(id, privacy: .public): Frost's controls were disturbed; not retrying")
                    } else if mover.isShuttingDown {
                        FrostLog.capture.error("background capture of item \(id, privacy: .public): moving it back failed while quitting (\(restoreError, privacy: .public)); the next launch moves it back")
                    } else {
                        FrostLog.capture.error("background capture of item \(id, privacy: .public): moving it back failed (\(restoreError, privacy: .public)); retrying under a new freeze frame")
                        scheduleCoveredRestore(plan, controls: controls, returnIdentity: returnIdentity)
                    }
                }
                if case .restored = back {
                    app.newItems.clearPendingReturn(returnIdentity)
                    scanner.rescan()
                    restoredExactly = Self.sectionOrder(SectionAssigner.layout(of: scanner.items, controls: controls))
                        == Self.sectionOrder(before)
                }
                try? await Task.sleep(for: MenuBarFreezeFrame.settleDelay)
                outcome = ObscuredCapturePolicy.outcome(of: attempt, hadPrevious: hadPrevious, moveFailed: moveFailed)
            }
        } catch {
            // `.busy` / `.shuttingDown`: another transaction started first or Frost is quitting; nothing was moved.
            app.obscuredCapture.record(.interrupted, for: id, now: .now)
            return
        }
        timing.total = clock.now - start
        app.obscuredCapture.record(outcome, for: id, now: .now)
        let slot = restoredExactly ? "back in its exact slot" : "NOT back in its exact slot"
        FrostLog.capture.notice("""
            background capture of item \(id, privacy: .public) (\(next.need.rawValue, privacy: .public)): \
            \(Self.describe(outcome), privacy: .public), \(slot, privacy: .public); \(timing.description, privacy: .public)
            """)
        replayInterceptedClick()
    }

    enum MoveBack {
        case restored
        /// A mouse button stayed held past `ObscuredCapturePolicy.holdCoverageLimit`: moved back later.
        case handedOff
        /// Frost is quitting while a mouse button is held: the next launch moves it back.
        case leftForNextLaunch
        case failed(Error)
    }

    /// Moves the item back while `freeze` covers the menu bar, keeping it up for as long as that takes
    /// (`ObscuredCapturePolicy.RestoreStep`): waits for a held mouse button to be released (extending the freeze frame's
    /// safety net meanwhile) and moves the item back the moment it is.
    private func moveBackUnderFreezeFrame(_ plan: RestorePlan, controls: FrostControlWindows,
                                          freeze: MenuBarFreezeFrame) async -> MoveBack {
        let mover = app.mover
        let clock = ContinuousClock()
        let waitStart = clock.now
        var shutdownSeen: ContinuousClock.Instant?
        var logged = false
        while true {
            if mover.isShuttingDown, shutdownSeen == nil { shutdownSeen = clock.now }
            switch ObscuredCapturePolicy.restoreStep(isMouseButtonHeld: UserMouseButtons.isAnyHeld,
                                                     waited: clock.now - waitStart,
                                                     sinceShutdown: shutdownSeen.map { clock.now - $0 }) {
            case .restoreNow:
                freeze.extendLimit(ObscuredCapturePolicy.restoreCoverage(
                    mouseReleaseTimeout: ItemMover.mouseReleaseTimeout(isShuttingDown: mover.isShuttingDown)))
                if let error = await restore(plan, controls: controls, until: .settled) { return .failed(error) }
                return .restored
            case .waitForRelease:
                if !logged {
                    logged = true
                    FrostLog.capture.notice("background capture: waiting for the mouse button to be released to move the item back (freeze frame stays up)")
                }
                freeze.extendLimit(Self.obscuredFreezeLimit)
                try? await Task.sleep(for: ObscuredCapturePolicy.holdPoll)
            case .handOff:
                return .handedOff
            case .leaveForNextLaunch:
                return .leftForNextLaunch
            }
        }
    }

    /// Moves an item a background capture couldn't move back in time back into its section, under a fresh freeze frame:
    /// once the user releases the mouse button (cancelling the task, when quitting or before a click forward, skips that
    /// wait). Runs as `restoreRetryTask`, so quitting waits for it and background captures don't start meanwhile. If it
    /// fails, the item's recorded return (`returnIdentity`) is left for the next launch.
    func scheduleCoveredRestore(_ plan: RestorePlan, controls: FrostControlWindows, returnIdentity: ItemIdentity?) {
        restoreRetryTask?.cancel()
        restoreRetryTask = Task { [weak self] in
            while UserMouseButtons.isAnyHeld, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            // The move itself runs in a task that doesn't inherit cancellation.
            await Task { @MainActor [weak self] in
                await self?.coveredRestore(plan, controls: controls, returnIdentity: returnIdentity)
            }.value
            self?.restoreRetryTask = nil
        }
    }

    private func coveredRestore(_ plan: RestorePlan, controls: FrostControlWindows,
                                returnIdentity: ItemIdentity?) async {
        let mover = app.mover, sections = app.sections
        interceptedClick = nil
        // The screenshot must show the menu bar as it is when the transaction starts: retake it if a move ran meanwhile.
        var screenshot: MenuBarFreezeFrame.Capture?
        for _ in 0..<3 {
            _ = await mover.waitUntilIdle(timeout: .seconds(5))
            // A freeze frame only in the collapsed state (it would hide a collapse while editing or expanded).
            guard sections.state == .collapsed, !sections.isEditing else { break }
            let before = mover.transactionCount
            screenshot = await MenuBarFreezeFrame.capture(
                menuBarFallbackHeight: sections.iconWindow?.frame.height ?? 24, iconFrames: frostIconFrames,
                managedDisplayID: managedDisplayID, contentCache: app.capturer.contentCache, coverage: .wholeMenuBar)
            if !mover.isBusy, mover.transactionCount == before { break }
            screenshot = nil
        }
        if screenshot == nil {
            FrostLog.capture.error("moving a background-captured item back without a freeze frame (none available)")
        }
        do {
            // Putting the icon back is exactly what quitting waits for, so it may run while shutting down.
            try await mover.transaction(allowedDuringShutdown: true) {
                var freeze: MenuBarFreezeFrame?
                if let screenshot {
                    freeze = await MenuBarFreezeFrame.show(
                        screenshot,
                        limit: ObscuredCapturePolicy.restoreCoverage(
                            mouseReleaseTimeout: ItemMover.mouseReleaseTimeout(isShuttingDown: mover.isShuttingDown)),
                        level: MenuBarFreezeFrame.aboveDragImagesLevel
                    ) { [weak self] event in
                        self?.freezeFrameTookClick(event)
                    }
                }
                defer { freeze?.remove() }
                if sections.isEditing {
                    try await sections.whileCollapsedForMove { try await self.restoreIfNeeded(plan, controls: controls) }
                } else {
                    if sections.state != .collapsed {
                        sections.setState(.collapsed)
                        await sections.waitForSettle()
                    }
                    try await restoreIfNeeded(plan, controls: controls)
                }
                if freeze != nil { try? await Task.sleep(for: MenuBarFreezeFrame.settleDelay) }
            }
            app.newItems.clearPendingReturn(returnIdentity)
            FrostLog.capture.notice("moved a background-captured item back under a new freeze frame")
        } catch {
            FrostLog.capture.error("moving a background-captured item back failed (\(error, privacy: .public)); the next launch moves it back")
        }
        replayInterceptedClick()
    }

    /// Moves the item right of the Frost icon, giving up as soon as the user needs the menu bar: a ⌘-drag cut short by
    /// the user's mouse-down doesn't take effect, and `ItemMover` would otherwise wait for the button to be released and
    /// try again, just to move the item back right after. The move runs in its own task, cancelled by a watcher (the
    /// move checks for cancellation between attempts and while waiting); the operation's own task isn't cancelled, so
    /// moving back still works. The pointer isn't watched: it's warped to the Frost icon during each ⌘-drag.
    private func moveOutUnlessInterrupted(_ id: CGWindowID, controls: FrostControlWindows) async throws {
        let mover = app.mover
        let move = Task { @MainActor in try await mover.move(id, to: .rightOf(controls.icon), until: .itemLanded) }
        let watcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.interceptedClick != nil || UserMouseButtons.isAnyHeld || self.isOpen
                    || self.activationTask != nil || mover.isShuttingDown || self.app.presence.isAway {
                    FrostLog.capture.notice("background capture: interrupted while moving the item out")
                    move.cancel()
                    return
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { watcher.cancel() }
        try await move.value
    }

    #if DEBUG
    /// Environment variable `FROST_TEST_OBSCURED_RESTORE_PAUSE_MS=<ms>` (VM testing only): pause between the capture
    /// and the move back, so a test can press a mouse button while the item sits right of the Frost icon.
    private static let testRestorePause: Duration? = ProcessInfo.processInfo
        .environment["FROST_TEST_OBSCURED_RESTORE_PAUSE_MS"].flatMap(Int.init).map { .milliseconds($0) }
    #endif

    /// The freeze frame's safety net for this operation: a move out, a capture and a move back normally take about a
    /// second (two ⌘-drags with their settle waits); retries take longer. Once the item is to be moved back, the safety
    /// net is extended for as long as that may take (`moveBackUnderFreezeFrame`): the overlay never goes while the item
    /// still sits in the Visible section.
    private static let obscuredFreezeLimit: Duration = .seconds(8)

    /// The freeze frame took a mouse-down: the operation stops at its next checkpoint.
    private func freezeFrameTookClick(_ event: NSEvent) {
        guard interceptedClick == nil else { return }
        let location = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation
        let context = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        interceptedClick = InterceptedClick(location: location, isContextClick: context,
                                            option: event.modifierFlags.contains(.option))
        FrostLog.capture.notice("background capture: a click on the frozen menu bar; moving the item back")
    }

    /// After the operation: a click the freeze frame took on the Frost icon is handled now. The icon is back where the
    /// freeze frame showed it, so its current frames tell where the user clicked.
    private func replayInterceptedClick() {
        guard let click = interceptedClick else { return }
        interceptedClick = nil
        guard frostIconFrames.contains(where: { $0.contains(click.location) }) else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(click.location, $0.frame, false) }
        app.sections.replayIconClick(context: click.isContextClick, option: click.option, screen: screen)
    }

    /// Window IDs per section, left to right (to check an item went back to its exact slot).
    private static func sectionOrder(_ layout: MenuBarLayout) -> [MenuBarSection: [CGWindowID]] {
        layout.mapValues { $0.map(\.windowID) }
    }

    private static func describe(_ outcome: ObscuredCapturePolicy.Outcome) -> String {
        switch outcome {
        case .captured(let changed):
            switch changed {
            case nil: "captured"
            case true?: "captured (changed)"
            case false?: "captured (unchanged)"
            }
        case .failed: "failed"
        case .interrupted: "interrupted"
        case .notApplicable: "not applicable"
        }
    }
}

/// Phases of one background capture (for the log).
struct ObscuredCaptureTiming: CustomStringConvertible {
    var screenshot: Duration = .zero
    var freezeFrame: Duration = .zero
    var moveOut: Duration = .zero
    var landed: Duration = .zero
    var capture: Duration = .zero
    var moveBack: Duration = .zero
    var overlay: Duration = .zero
    var total: Duration = .zero

    var description: String {
        let ms = LiveRefreshStats.Timing.ms
        return "screenshot \(ms(screenshot)), freeze frame \(ms(freezeFrame)), out \(ms(moveOut)), "
            + "on screen \(ms(landed)), capture \(ms(capture)), back \(ms(moveBack)), "
            + "overlay up \(ms(overlay)), total \(ms(total))"
    }
}
