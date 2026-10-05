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
    /// when an expanded scan finds new ones, on a manual refresh, and at the end of each operation's wait. Runs only
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
                // Move back (also when the move out failed: `move` finds the item in place and returns). Waits until
                // every window has stopped sliding, then a frame or two for the menu bar to redraw before the freeze
                // frame goes.
                mark = clock.now
                let restoreError = await restore(plan, controls: controls, until: .settled)
                timing.moveBack = clock.now - mark
                if let restoreError {
                    moveFailed = true
                    if case ItemMoveError.controlsDisturbed = restoreError {
                        FrostLog.capture.error("background capture of item \(id, privacy: .public): Frost's controls were disturbed; not retrying")
                    } else {
                        FrostLog.capture.error("background capture of item \(id, privacy: .public): moving it back failed (\(restoreError, privacy: .public)); retrying in 1.5 s")
                        scheduleRestoreRetry(plan, controls: controls)
                    }
                } else {
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

    /// The freeze frame's safety net for this operation: a move out, a capture and a move back normally take about a
    /// second (two ⌘-drags with their settle waits); retries take longer.
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
