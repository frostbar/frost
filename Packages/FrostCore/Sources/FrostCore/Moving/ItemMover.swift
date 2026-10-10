import AppKit

public enum ItemMoveError: Error, Equatable, Sendable {
    case itemNotFound
    case targetNotFound
    case immovable
    case didNotMove
    /// Another move transaction (an editor drag-and-drop or a Frost Bar click forward) is in progress.
    case busy
    /// The Frost icon can't be found (`controlWindows` not injected / not in the scan results / not on screen).
    /// The mouse-down must physically land on the Frost icon; without it moving is unsafe, so no events are sent.
    case frostIconUnavailable
    /// After the move, the order of Frost's own controls (AH < H < Icon) was disturbed: routing degraded to
    /// position-based and the Frost icon was dragged instead. One attempt has been made to move the icon back to
    /// the right of H (not guaranteed to succeed).
    case controlsDisturbed
    /// Frost is quitting (`ItemMover.beginShutdown`): no new move transaction may start, so the app never exits in
    /// the middle of a ⌘-drag that a queued drop or a new-item placement started right before the quit.
    case shuttingDown
    /// The user kept a mouse button held for longer than `ItemMover.mouseReleaseTimeout`: no ⌘-drag was posted.
    case mouseButtonHeld
}

/// Moves menu bar items with a synthetic ⌘-drag (implemented per macos-behavior.md, "Task 11").
///
/// - Every event sets field `0x33 = dragged item's windowID`, so the system routes by windowID rather than by
///   cursor position.
/// - The mouse-down physically lands on the center of the Frost icon: it is always visible and is Frost's own
///   item. Even if routing degrades to position-based, the worst case is dragging Frost's own icon, never a
///   third-party icon. This is also why off-screen items (pushed off / under the notch) can be moved.
/// - No dragged events: down → (the item is lifted; see `DragRelease`) → up. The drop position is determined by the
///   mouseUp's raw coordinates (which may be off screen) against the menu bar as it is while the item is lifted.
@MainActor
public final class ItemMover {
    private let scanner: MenuBarItemScanner

    /// Window IDs of Frost's three controls, injected by the app layer (`FrostControlLocator`). `move` uses the
    /// icon as the mouse-down position.
    public var controlWindows: () -> FrostControlWindows? = { nil }

    /// Called with true before a move posts its ⌘-drag (whose mouse-down physically lands on the Frost icon) and with
    /// false once the move's frames have settled (the events have long been handled by then). The app layer keeps the
    /// Frost icon from drawing a pressed highlight meanwhile.
    public var syntheticDragActive: (Bool) -> Void = { _ in }

    /// Called with the milestones of each ⌘-drag (`down`, `lifted`, `up`, then `landed` or `settled`) and the instant
    /// each happened, so the Frost Bar's click forward can break its latency down (`ForwardTrace`).
    public var milestone: (_ label: String, _ at: ContinuousClock.Instant) -> Void = { _, _ in }

    /// Whether the user holds a mouse button (injectable for tests). A ⌘-drag posted meanwhile gets mixed up with the
    /// user's own drag: their drag events carry the item along, even off the menu bar, where releasing removes it
    /// (measured in the VM: a queued layout editor drop's retry ran while the user dragged the next tile). So every
    /// attempt first waits for the buttons to be released (`waitForMouseButtonsReleased`).
    public var isMouseButtonHeld: () -> Bool = { UserMouseButtons.isAnyHeld }

    /// Whether a menu is open (injectable for tests). A ⌘-drag posted while one is open doesn't take effect (menu
    /// tracking takes the mouse-down) and closes the menu: measured in the VM, a menu the user opened on the menu bar
    /// right before a Frost Bar move back closed ~0.4 s later and the move needed a second attempt. Moves that can wait
    /// (`yieldingToMenus`) wait for it to close first.
    public var isMenuOpen: () -> Bool = { ItemClicker.isMenuOnScreen() }
    /// How long a move `yieldingToMenus` waits for an open menu before it goes ahead anyway.
    public var menuYieldTimeout: Duration = .seconds(30)

    public var maxAttempts = 3
    /// Attempts the user's own mouse may cut short (or keep from being posted) on top of `maxAttempts`
    /// (`MoveAttempts`).
    public var maxInterruptions = 4
    /// Delay after posting events before the first check; then poll every `pollInterval` until the order is
    /// correct and frames are stable, for at most `settleTimeout`.
    /// Measured: the order is correct after 32–40 ms; on-screen move animations finish in 390–540 ms, moves
    /// between off-screen positions in 94–152 ms.
    public var initialSettleDelay: Duration = .milliseconds(50)
    public var pollInterval: Duration = .milliseconds(25)
    public var settleTimeout: Duration = .seconds(1)
    /// `.itemLanded` moves: how often the item's frame is checked after the mouse-up, and how long to wait for it to land
    /// before falling back to waiting for every window to settle (the slide of the other windows takes ~0.4 s).
    public var landingPollInterval: Duration = .milliseconds(8)
    public var landingTimeout: Duration = .milliseconds(700)

    /// When `move` returns after posting a ⌘-drag.
    public enum Completion: Sendable {
        /// Once every window on the menu bar has stopped moving (the order is right and the frames are stable).
        case settled
        /// As soon as the moved item has reached its final frame (`LandingDetector`), while the windows left of it may
        /// still be sliding. For a click that must follow at once (the Frost Bar's click forward); falls back to
        /// `.settled` if the item isn't seen landing within `landingTimeout`.
        case itemLanded
    }

    /// Whether a move transaction is in progress. `@MainActor` only prevents concurrent access; it doesn't keep a
    /// whole transaction spanning awaits from being interleaved, so every move (including Frost Bar's entire
    /// "move out → click → move back" flow) must be wrapped in `transaction`.
    public private(set) var isBusy = false
    /// Incremented whenever a transaction starts, so work prepared outside a transaction (the Frost Bar's freeze-frame
    /// screenshot) can tell whether a move may have happened meanwhile.
    public private(set) var transactionCount = 0

    /// Frost is quitting (`beginShutdown`): new transactions throw `.shuttingDown` unless they are the move-back
    /// work quitting itself runs, and every move gets at most `shutdownMaxAttempts` attempts so quitting stays
    /// responsive.
    public private(set) var isShuttingDown = false
    /// Attempts per move once shutting down (instead of `maxAttempts`).
    public var shutdownMaxAttempts = 1

    /// Windows this mover posted a ⌘-drag for since the last `takeMovedWindowIDs()`. Section changes of these windows
    /// were Frost's doing, not the user's (see `SectionKeeper`).
    public private(set) var movedWindowIDs: Set<CGWindowID> = []

    /// Returns `movedWindowIDs` and starts over.
    public func takeMovedWindowIDs() -> Set<CGWindowID> {
        defer { movedWindowIDs = [] }
        return movedWindowIDs
    }

    /// Which ⌘-drag this mover posts (`MenuBarBackend`).
    public enum Mechanism: Sendable {
        /// macOS 26: the mouse-down lands on Frost's own icon and CGEvent field `0x33` routes the drag to the
        /// target item's window, whatever its position. Nothing is posted at a third-party item.
        case windowIDRouting
        /// macOS 27: there are no per-item windows and no routing, so the drag has to start **on the item itself**,
        /// at its verified center. That is a synthesized ⌘ mouse-down on another app's status item; it only ever
        /// happens for a move the user asked for (a layout drop, a Frost Bar click), inside
        /// `ItemMover.transaction`, with the pointer concealed, and only after the item's identity and current
        /// geometry were read from Accessibility and one positive hit confirmed it is drawn there.
        case directOnTarget
    }

    public var mechanism: Mechanism = .windowIDRouting

    /// The live item list on macOS 27 (`scanner.items`: read from Accessibility) and a way to force a fresh read.
    /// Used instead of the window list, which has nothing to say there.
    public var axItems: () -> [MenuBarItem] = { [] }
    public var axRefresh: () async -> Void = {}

    public init(scanner: MenuBarItemScanner) { self.scanner = scanner }

    /// Runs a move transaction exclusively; throws `.busy` immediately if one is already in progress (the caller
    /// decides: the layout editor and the Frost Bar click forward wait for `isBusy` to become false first, see
    /// `waitUntilIdle`). Once shutting down, throws `.shuttingDown` unless `allowedDuringShutdown` (moving an icon
    /// back to its section while quitting).
    public func transaction<T>(allowedDuringShutdown: Bool = false, _ body: () async throws -> T) async throws -> T {
        guard !isShuttingDown || allowedDuringShutdown else { throw ItemMoveError.shuttingDown }
        guard !isBusy else { throw ItemMoveError.busy }
        isBusy = true
        transactionCount &+= 1
        defer { isBusy = false }
        return try await body()
    }

    /// Frost is about to quit: from now on only transactions `allowedDuringShutdown` may start. Irreversible.
    public func beginShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        FrostLog.mover.notice("shutting down: no new move transactions")
    }

    /// Waits (polling every `poll`) until no transaction is running; returns false if one is still running after
    /// `timeout` (or when the waiting task is cancelled while one is running). Callers that then start a
    /// transaction must not suspend between this returning true and calling `transaction`, so nothing can slip in.
    public func waitUntilIdle(timeout: Duration, poll: Duration = .milliseconds(50)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while isBusy {
            guard clock.now < deadline else { return false }
            do { try await Task.sleep(for: poll) } catch { return !isBusy }
        }
        return true
    }

    /// Moves the item to `destination`. After each attempt, polls until the order is correct and frames are stable
    /// before returning (a rescan has happened, so `scanner.items` holds the final positions); if the move didn't
    /// take effect, waits for frames to settle and retries, up to `maxAttempts` times.
    /// When the item or target is under the notch (see `isVerifiable`), the move is never skipped just because it
    /// "looks in place". Verification after the move is equally unreliable in that case, so callers should first
    /// get the relevant items into trustworthy positions where possible (the layout editor temporarily collapses
    /// the menu bar while moving).
    /// Must be called inside `transaction` (`assert(isBusy)` in debug). Throws `CancellationError` when the task
    /// is cancelled.
    /// `completion`: see `Completion`. `cursor`: where the pointer ends up (`CursorDisposition`); it is hidden while
    /// the ⌘-drag moves it either way.
    /// `yieldingToMenus`: before each attempt, wait (up to `menuYieldTimeout`, not while quitting) for an open menu to
    /// close, so a move the user isn't waiting for (moving an item back) doesn't close the menu they just opened.
    public func move(_ itemID: CGWindowID, to destination: MoveDestination,
                     until completion: Completion = .settled, cursor: CursorDisposition = .restore,
                     yieldingToMenus: Bool = false) async throws {
        try await move(itemID, to: destination, attempts: maxAttempts, checkingControls: true, completion: completion,
                       cursor: cursor, yieldingToMenus: yieldingToMenus)
    }

    /// - `checkingControls`: after each attempt, check the order of Frost's controls (see `controlsInOrder`); if
    ///   disturbed, move the icon back to `.rightOf(H)` once and throw `.controlsDisturbed` (no further retries:
    ///   retrying would just keep dragging the icon).
    private func move(_ itemID: CGWindowID, to destination: MoveDestination, attempts: Int,
                      checkingControls: Bool, completion: Completion = .settled,
                      cursor disposition: CursorDisposition = .restore, yieldingToMenus: Bool = false) async throws {
        assert(isBusy, "ItemMover.move must be called inside transaction")
        if mechanism == .directOnTarget {
            return try await moveDirect(itemID, to: destination, attempts: attempts, cursor: disposition)
        }
        var tally = MoveAttempts(limit: attempts, interruptionLimit: maxInterruptions,
                                 shutdownLimit: shutdownMaxAttempts)
        // Quitting began during this move: stop retrying (checked per attempt, so a move that was already retrying
        // finishes its current attempt and then gives up).
        while tally.mayAttempt(isShuttingDown: isShuttingDown) {
            try Task.checkCancellation()
            let attempt = tally.count + 1
            if yieldingToMenus, !isShuttingDown { try await waitForMenusToClose(timeout: menuYieldTimeout) }
            // Before reading any frame: the mouse-down must land on the Frost icon where it is when posting.
            try await waitForMouseButtonsReleased(timeout: Self.mouseReleaseTimeout(isShuttingDown: isShuttingDown))
            scanner.rescan()
            let items = scanner.items
            guard let item = items.first(where: { $0.windowID == itemID }) else { throw ItemMoveError.itemNotFound }
            guard item.isMovable else { throw ItemMoveError.immovable }
            guard let target = items.first(where: { $0.windowID == destination.targetWindowID })
            else { throw ItemMoveError.targetNotFound }
            let frames = Self.frames(of: items)
            let verifiable = Self.isVerifiable(item, target: target, displayBounds: menuBarDisplayBounds)
            if verifiable, Self.isSatisfied(itemID, destination, frames: frames) { return }
            guard let iconID = controlWindows()?.icon,
                  let icon = items.first(where: { $0.windowID == iconID }), icon.isOnScreen
            else { throw ItemMoveError.frostIconUnavailable }

            let down = CGPoint(x: icon.frame.midX, y: icon.frame.midY)
            let up = Self.dropPoint(for: destination, targetFrame: target.frame)
            let known = Set(frames.keys)
            let release = DragRelease(
                itemID: itemID, destination: destination, originalFrame: item.frame,
                waitsForStillness: DragRelease.targetMaySlide(itemFrame: item.frame, destination: destination,
                                                              targetFrame: target.frame, iconID: iconID,
                                                              iconFrame: icon.frame))
            movedWindowIDs.insert(itemID)
            syntheticDragActive(true)
            defer { syntheticDragActive(false) }
            let posted = await Task.detached {
                Self.postCommandDrag(windowID: itemID, mouseDown: down, plannedMouseUp: up, release: release,
                                     watching: known, cursor: disposition)
            }.value
            // A move out left the pointer hidden at the drop point: it reappears once the item has landed (below). On
            // every other way out of this attempt (an error, cancellation, a retry) it goes back where it was.
            defer { posted.concealment?.end(warpingTo: posted.savedCursor) }
            guard posted.downAt != nil else {
                // The user pressed a mouse button between the check above and the mouse-down: nothing was posted.
                FrostLog.mover.notice("""
                    ⌘-drag of \(itemID, privacy: .public) not posted: a mouse button went down right before it
                    """)
                tally.record(.notPosted)
                continue
            }
            FrostLog.mover.info("""
                ⌘-drag of \(itemID, privacy: .public) to \(String(describing: destination), privacy: .public) \
                (attempt \(attempt, privacy: .public)): \(posted.description, privacy: .public)
                """)
            if let downAt = posted.downAt { milestone("down", downAt) }
            if let liftedAt = posted.liftedAt { milestone("lifted", liftedAt) }
            if let releasedAt = posted.releasedAt { milestone("up", releasedAt) }

            let snapshot = { Self.frames(of: StatusWindowParser.windows(withIDs: known)) }
            let satisfied = { Self.isSatisfied(itemID, destination, frames: $0) }
            let result: SettleResult
            let clock = ContinuousClock()
            let settleStart = clock.now
            if completion == .itemLanded,
               try await Self.waitForLanding(LandingDetector(itemID: itemID, destination: destination),
                                             interval: landingPollInterval, timeout: landingTimeout,
                                             snapshot: snapshot) {
                result = SettleResult(satisfied: true, settled: false)
                milestone("landed", .now)
            } else {
                let elapsed = clock.now - settleStart
                result = try await Self.waitForSettle(
                    initialDelay: completion == .itemLanded ? .zero : initialSettleDelay, interval: pollInterval,
                    timeout: Self.remainingSettleTimeout(settleTimeout, elapsed: elapsed), snapshot: snapshot,
                    satisfied: satisfied)
                milestone("settled", .now)
            }
            if let concealment = posted.concealment {
                let landed = result.satisfied ? snapshot()[itemID] : nil
                concealment.end(warpingTo: CursorPlacement.finalPosition(
                    disposition, saved: posted.savedCursor, landedItemFrame: landed, displayBounds: menuBarDisplayBounds))
            }
            if checkingControls, let controls = controlWindows(), itemID != controls.icon,
               !Self.controlsInOrder(controls, windows: StatusWindowParser.windows(withIDs: controls.all),
                                     displayBounds: menuBarDisplayBounds) {
                FrostLog.mover.error("Frost's controls are out of order after moving \(itemID); moving the icon back")
                do {
                    try await move(controls.icon, to: .rightOf(controls.hiddenSeparator), attempts: 1,
                                   checkingControls: false)
                } catch {
                    FrostLog.mover.error("could not move the Frost icon back: \(error, privacy: .public)")
                }
                scanner.rescan()
                throw ItemMoveError.controlsDisturbed
            }
            if result.satisfied {
                scanner.rescan()
                return
            }
            if posted.interrupted {
                FrostLog.mover.notice("""
                    ⌘-drag of \(itemID, privacy: .public) was cut short by the user's mouse button and didn't take \
                    effect; trying again once the button is released
                    """)
            }
            tally.record(posted.interrupted ? .interrupted : .failed)
        }
        throw ItemMoveError.didNotMove
    }

    // MARK: - macOS 27: direct ⌘-drag on the item

    /// Moves an item by ⌘-dragging it from its own center (`Mechanism.directOnTarget`).
    ///
    /// The caller reveals both sections first: a hidden item keeps reporting its old frame, so its center is not
    /// where the drag would have to start, and the destination's neighbours have to be where they are drawn.
    ///
    /// Every attempt: read the current order and geometry from Accessibility, stop if the item is already where it
    /// belongs, post the drag (mouse-down on the item's verified center, drag events to the point next to the target,
    /// mouse-up), then read the order back until the item is next to the target — the *observed* order is the only
    /// thing that counts as success, never a delay or a requested position. If it isn't next to the target after
    /// `maxAttempts`, the move failed and the caller reports that.
    private func moveDirect(_ itemID: CGWindowID, to destination: MoveDestination, attempts: Int,
                            cursor disposition: CursorDisposition) async throws {
        var tally = MoveAttempts(limit: attempts, interruptionLimit: maxInterruptions,
                                 shutdownLimit: shutdownMaxAttempts)
        while tally.mayAttempt(isShuttingDown: isShuttingDown) {
            try Task.checkCancellation()
            // A synthetic drag must never overlap the user's own: their drag events would carry the item along.
            try await waitForMouseButtonsReleased(timeout: Self.mouseReleaseTimeout(isShuttingDown: isShuttingDown))
            await axRefresh()
            let items = axItems()
            guard let item = items.first(where: { $0.windowID == itemID }) else { throw ItemMoveError.itemNotFound }
            guard item.isMovable else { throw ItemMoveError.immovable }
            guard let target = items.first(where: { $0.windowID == destination.targetWindowID })
            else {
                FrostLog.mover.error("""
                    target of \(String(describing: destination), privacy: .public) is not among the \
                    \(items.count, privacy: .public) items the bar reports
                    """)
                throw ItemMoveError.targetNotFound
            }
            let frames = Self.frames(of: items)
            if Self.isSatisfiedOn27(itemID, destination, frames: frames, controls: controlWindows()) { return }

            let down = CGPoint(x: item.frame.midX, y: item.frame.midY)
            // The mouse-down has to land on *this* item. Its frame is what Accessibility reports, and an item the bar
            // isn't drawing keeps reporting the frame it had — posting there would press whatever is actually at that
            // point, possibly another app's status item. The system is asked which element is at the point; if that is
            // not this item, nothing is posted.
            guard let pid = item.pid, let identityKey = item.identityKey,
                  await Self.verifyItemAt(down, pid: pid, identityKey: identityKey) else {
                FrostLog.mover.notice("""
                    not posting a ⌘-drag of \(itemID, privacy: .public): Accessibility does not report it at                     (\(Int(down.x), privacy: .public), \(Int(down.y), privacy: .public)), the point the mouse-down                     would land on
                    """)
                tally.record(.notPosted)
                continue
            }
            // The item is lifted out of the layout while it is dragged, so the windows that were between its old and
            // its new slot slide over by its width; the mouse-up is aimed with that in mind and corrected afterwards
            // from the observed result rather than from a formula.
            let planned = Self.dropPoint(for: destination, targetFrame: target.frame)
            movedWindowIDs.insert(itemID)
            syntheticDragActive(true)
            defer { syntheticDragActive(false) }
            let posted = await Task.detached {
                Self.postDirectDrag(mouseDown: down, mouseUp: planned, cursor: disposition)
            }.value
            defer { posted.concealment?.end(warpingTo: posted.savedCursor) }
            guard posted.downAt != nil else {
                FrostLog.mover.notice("""
                    ⌘-drag of \(itemID, privacy: .public) not posted: a mouse button went down right before it
                    """)
                tally.record(.notPosted)
                continue
            }
            FrostLog.mover.info("""
                direct ⌘-drag of \(itemID, privacy: .public) \(String(describing: destination), privacy: .public) \
                (attempt \(tally.count + 1, privacy: .public)): \(posted.description, privacy: .public)
                """)
            var satisfied = false
            var landed: CGRect?
            for _ in 0..<Self.directVerifyPolls {
                try? await Task.sleep(for: Self.directVerifyInterval)
                await axRefresh()
                let current = Self.frames(of: axItems())
                landed = current[itemID]
                if Self.isSatisfiedOn27(itemID, destination, frames: current, controls: controlWindows()) {
                    satisfied = true
                    break
                }
            }
            if let concealment = posted.concealment {
                concealment.end(warpingTo: CursorPlacement.finalPosition(disposition, saved: posted.savedCursor,
                                                                        landedItemFrame: landed,
                                                                        displayBounds: menuBarDisplayBounds))
            }
            if satisfied {
                FrostLog.mover.info("""
                    direct ⌘-drag of \(itemID, privacy: .public) verified against the order the menu bar reports
                    """)
                return
            }
            if posted.interrupted {
                FrostLog.mover.notice("""
                    direct ⌘-drag of \(itemID, privacy: .public) was cut short by the user's mouse button; trying \
                    again once it is released
                    """)
            }
            tally.record(posted.interrupted ? .interrupted : .failed)
        }
        throw ItemMoveError.didNotMove
    }

    /// Whether a direct drag has reached its destination.
    ///
    /// Same rule as `isSatisfied` when the destination is another icon: the item has to end up next to it. A drop
    /// at the *end* of a section is resolved against one of Frost's own dividers instead, and on 27 that divider is
    /// an *invisible 8 pt line* while the editor is open: "immediately beside it" is stricter than the bar can
    /// express there, so the check is the one the user actually asked for — the item is the last one of that section,
    /// i.e. it is left of the divider and no other icon of the user's sits between the two.
    ///
    /// "Anywhere left of the divider" would be wrong in both directions: an icon that is already in the Hidden
    /// section would count as arrived wherever it is (a drop that should move it to the end would report success
    /// without moving anything), and an icon that failed to leave a band wouldn't be noticed.
    nonisolated static func isSatisfiedOn27(_ itemID: CGWindowID, _ destination: MoveDestination,
                                            frames: [CGWindowID: CGRect],
                                            controls: FrostControlWindows?) -> Bool {
        guard let controls,
              destination.targetWindowID == controls.hiddenSeparator
                || destination.targetWindowID == controls.alwaysHiddenSeparator,
              let item = frames[itemID], let divider = frames[destination.targetWindowID],
              item.midX < divider.midX
        else { return isSatisfied(itemID, destination, frames: frames) }
        return !frames.contains { id, frame in
            id != itemID && !controls.all.contains(id) && frame.width > 0
                && frame.midX > item.midX && frame.midX < divider.midX
        }
    }

    /// The hit test runs off the main thread (an Accessibility round trip).
    nonisolated static func verifyItemAt(_ point: CGPoint, pid: pid_t, identityKey: String) async -> Bool {
        await Task.detached { AXExtrasReader.isItemAt(point, pid: pid, identityKey: identityKey) }.value
    }

    /// How often and how long the order is read back after a direct drag (an Accessibility read takes about 100 ms
    /// per app, so this is slow on purpose: the item has to be seen in its slot, not assumed to be).
    nonisolated static let directVerifyInterval: Duration = .milliseconds(150)
    nonisolated static let directVerifyPolls = 10

    /// The direct drag's report: when the mouse-down was posted (nil: never), and the concealment to end.
    struct PostedDirectDrag: Sendable {
        var downAt: ContinuousClock.Instant?
        var savedCursor: CGPoint?
        var concealment: CursorConcealment?
        var interrupted = false

        var description: String { downAt == nil ? "not posted" : (interrupted ? "cut short by the user" : "posted") }
    }

    /// Posts the ⌘-drag from `mouseDown` (the item's own center) to `mouseUp`. On a background thread: it sleeps
    /// between events, and the main thread has to stay free to handle them.
    nonisolated static func postDirectDrag(mouseDown: CGPoint, mouseUp: CGPoint,
                                           cursor disposition: CursorDisposition = .restore) -> PostedDirectDrag {
        SyntheticEventGate.posting { postDirectDragNow(mouseDown: mouseDown, mouseUp: mouseUp, cursor: disposition) }
    }

    private nonisolated static func postDirectDragNow(mouseDown: CGPoint, mouseUp: CGPoint,
                                                      cursor disposition: CursorDisposition) -> PostedDirectDrag {
        var report = PostedDirectDrag()
        guard !UserMouseButtons.isAnyHeld else { return report }
        let presses = UserMouseButtons.pressCount
        let source = CGEventSource(stateID: .hidSystemState)
        report.savedCursor = CGEvent(source: nil)?.location
        let concealment = CursorConcealment.begin()

        func event(_ type: CGEventType, _ point: CGPoint) -> CGEvent? {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                      mouseButton: .left) else { return nil }
            event.flags = .maskCommand
            return event
        }
        // No window-ID field: on 27 it routes nothing, the drag follows the pointer.
        guard let move = event(.mouseMoved, mouseDown), let down = event(.leftMouseDown, mouseDown) else {
            concealment.end(warpingTo: report.savedCursor)
            return report
        }
        move.post(tap: .cgSessionEventTap)
        down.post(tap: .cgSessionEventTap)
        report.downAt = .now
        usleep(80_000)
        // The first dragged event is what lifts the item; without it this is just a click.
        event(.leftMouseDragged, CGPoint(x: mouseDown.x + 2, y: mouseDown.y))?.post(tap: .cgSessionEventTap)
        let steps = 20
        for step in 1...steps {
            guard !UserMouseButtons.isAnyHeld, UserMouseButtons.pressCount == presses else {
                report.interrupted = true
                break
            }
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: mouseDown.x + (mouseUp.x - mouseDown.x) * t,
                                y: mouseDown.y + (mouseUp.y - mouseDown.y) * t)
            event(.leftMouseDragged, point)?.post(tap: .cgSessionEventTap)
            usleep(15_000)
        }
        // The pause before the mouse-up lets the item settle where it was dropped. Not when the user's own input cut
        // the drag short: the synthetic button is still down, so waiting here would let their movement carry the
        // status item along while they click.
        if !report.interrupted { usleep(120_000) }
        event(.leftMouseUp, mouseUp)?.post(tap: .cgSessionEventTap)
        usleep(40_000)
        if UserMouseButtons.pressCount != presses { report.interrupted = true }
        if CursorPlacement.restoresRightAfterDrag(disposition) {
            concealment.end(warpingTo: report.savedCursor)
        } else {
            report.concealment = concealment
        }
        return report
    }

    /// Waits (polling every `poll`) while the user holds a mouse button; throws `.mouseButtonHeld` if still held after
    /// `timeout`, `CancellationError` when cancelled.
    func waitForMouseButtonsReleased(timeout: Duration, poll: Duration = .milliseconds(20)) async throws {
        guard isMouseButtonHeld() else { return }
        FrostLog.mover.notice("waiting for the mouse button to be released before the next ⌘-drag")
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while isMouseButtonHeld() {
            guard clock.now < deadline else { throw ItemMoveError.mouseButtonHeld }
            try await Task.sleep(for: poll)
        }
    }

    /// Waits (polling every `poll`) while a menu is open, at most `timeout` and only until quitting begins; returns
    /// whether none is open any more. Throws `CancellationError` when cancelled.
    @discardableResult
    func waitForMenusToClose(timeout: Duration, poll: Duration = .milliseconds(50)) async throws -> Bool {
        guard isMenuOpen() else { return true }
        FrostLog.mover.notice("waiting for the open menu to close before the next ⌘-drag")
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        // Quitting doesn't wait for the user's menu.
        while isMenuOpen(), !isShuttingDown {
            guard clock.now < deadline else {
                FrostLog.mover.notice("a menu is still open after \(timeout, privacy: .public); moving anyway")
                return false
            }
            try await Task.sleep(for: poll)
        }
        return true
    }

    /// How long a move waits for the user to let go of a mouse button: as long as a deliberate drag takes, but briefly
    /// while quitting (which gives up after a few seconds anyway).
    public nonisolated static func mouseReleaseTimeout(isShuttingDown: Bool) -> Duration {
        isShuttingDown ? .seconds(1) : .seconds(30)
    }

    /// Bounds of the display hosting the scanned menu bar (the active menu bar, not necessarily the main
    /// display); needed to decide what is "under the notch".
    private var menuBarDisplayBounds: CGRect {
        scanner.menuBarDisplay?.frame ?? CGDisplayBounds(CGMainDisplayID())
    }

    // MARK: - Pure logic (unit tested)

    /// Whether the item is already immediately left/right of the target (sorted by minX; `frames` holds every
    /// item on the scanned menu bar, excluding copies on other displays).
    nonisolated static func isSatisfied(_ itemID: CGWindowID, _ destination: MoveDestination,
                                        frames: [CGWindowID: CGRect]) -> Bool {
        let ordered = frames.sorted { ($0.value.minX, $0.key) < ($1.value.minX, $1.key) }.map(\.key)
        guard let i = ordered.firstIndex(of: itemID) else { return false }
        switch destination {
        case .leftOf(let id): return i + 1 < ordered.count && ordered[i + 1] == id
        case .rightOf(let id): return i > 0 && ordered[i - 1] == id
        }
    }

    /// Whether Frost's controls are still ordered AH < H < Icon (by minX). The mouse-down physically lands on
    /// the Frost icon, so if routing degrades to position-based, the icon is what gets dragged; it lands at the
    /// target position (e.g. left of H) and the order is disturbed.
    /// Inconclusive (returns true) if any control is missing, or any control is under the notch (`onscreen=false`
    /// with its origin inside the screen bounds, so x is untrustworthy).
    /// Separators pushed off screen while collapsed are also `onscreen=false`, but their origin is left of the
    /// screen and their position is trustworthy.
    nonisolated static func controlsInOrder(_ controls: FrostControlWindows, windows: [RawStatusWindow],
                                            displayBounds: CGRect) -> Bool {
        let byID = Dictionary(windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        guard let alwaysHidden = byID[controls.alwaysHiddenSeparator], let hidden = byID[controls.hiddenSeparator],
              let icon = byID[controls.icon] else { return true }
        let ordered = [alwaysHidden, hidden, icon]
        let obscured = ordered.contains { !$0.isOnScreen && $0.frame.minX >= displayBounds.minX }
        guard !obscured else { return true }
        return alwaysHidden.frame.minX < hidden.frame.minX && hidden.frame.minX < icon.frame.minX
    }

    /// Items under the notch: they don't fit when expanded, so `isOnScreen == false`, yet their frame is still
    /// within the horizontal range of the (scanned) display. The system tucks them under the notch and their x
    /// doesn't reflect the real order (measured: they can end up left of the AH separator). Items pushed off
    /// screen by a separator (frame entirely left of the display) don't count: while collapsed their order is
    /// trustworthy.
    public nonisolated static func isObscured(_ item: MenuBarItem, displayBounds: CGRect) -> Bool {
        !item.isOnScreen && item.frame.maxX > displayBounds.minX
    }

    /// Whether the x order can tell if this move is already in place: neither the item nor the target is under the
    /// notch. If it can't, the move is not skipped because it "looks in place" (on real hardware that would make
    /// the move silently fail).
    nonisolated static func isVerifiable(_ item: MenuBarItem, target: MenuBarItem, displayBounds: CGRect) -> Bool {
        !isObscured(item, displayBounds: displayBounds) && !isObscured(target, displayBounds: displayBounds)
    }

    /// The mouseUp end point: `leftOf T → (T.minX + 1, T.midY)`, `rightOf T → (T.maxX − 1, T.midY)`.
    /// When the target is off screen (negative x) the raw coordinates are used as is, not clamped on screen.
    nonisolated static func dropPoint(for destination: MoveDestination, targetFrame: CGRect) -> CGPoint {
        switch destination {
        case .leftOf: CGPoint(x: targetFrame.minX + 1, y: targetFrame.midY)
        case .rightOf: CGPoint(x: targetFrame.maxX - 1, y: targetFrame.midY)
        }
    }

    nonisolated static func frames(of items: [MenuBarItem]) -> [CGWindowID: CGRect] {
        Dictionary(items.map { ($0.windowID, $0.frame) }, uniquingKeysWith: { a, _ in a })
    }

    nonisolated static func frames(of windows: [RawStatusWindow]) -> [CGWindowID: CGRect] {
        Dictionary(windows.map { ($0.windowID, $0.frame) }, uniquingKeysWith: { a, _ in a })
    }

    /// What is left of `timeout` after `elapsed` (an `.itemLanded` move that fell back to waiting for every window),
    /// but at least `minimumFallbackSettle`, so a move that didn't take effect still cools down before its retry.
    nonisolated static func remainingSettleTimeout(_ timeout: Duration, elapsed: Duration) -> Duration {
        max(timeout - elapsed, minimumFallbackSettle)
    }

    nonisolated static let minimumFallbackSettle: Duration = .milliseconds(300)

    /// Takes a snapshot right away, then every `interval`, until `detector` reports the moved item landed (true), or
    /// `timeout` passes (false). (The item usually lands within a few ms of the mouse-up, before the first snapshot.)
    static func waitForLanding(_ detector: LandingDetector, interval: Duration, timeout: Duration,
                               snapshot: () -> [CGWindowID: CGRect]) async throws -> Bool {
        var detector = detector
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            if detector.observe(snapshot()) { return true }
            guard clock.now < deadline else { return false }
            try await Task.sleep(for: interval)
        }
    }

    struct SettleResult: Equatable {
        /// Whether the last snapshot satisfies the target order.
        var satisfied: Bool
        /// Whether stability (3 consecutive identical snapshots) was observed before the timeout.
        var settled: Bool
    }

    /// After `initialDelay`, takes a snapshot every `interval`: returns as soon as the order is satisfied and two
    /// consecutive snapshots match the previous one (frames stable); otherwise returns the last state at
    /// `timeout` (measured from the start). If the move didn't take effect it waits until the timeout, which
    /// doubles as a cool-down before retrying.
    static func waitForSettle(initialDelay: Duration, interval: Duration, timeout: Duration,
                              snapshot: () -> [CGWindowID: CGRect],
                              satisfied: ([CGWindowID: CGRect]) -> Bool) async throws -> SettleResult {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        try await Task.sleep(for: initialDelay)
        var previous = snapshot()
        var unchanged = 0
        while clock.now < deadline {
            try await Task.sleep(for: interval)
            let current = snapshot()
            unchanged = current == previous ? unchanged + 1 : 0
            previous = current
            if unchanged >= 2, satisfied(current) { return SettleResult(satisfied: true, settled: true) }
        }
        return SettleResult(satisfied: satisfied(previous), settled: false)
    }

    // MARK: - Event synthesis

    /// Event field 0x33: routes mouse events by windowID (an undocumented field used by Ice, verified in the
    /// spike).
    nonisolated static let windowIDField = CGEventField(rawValue: 0x33)!

    /// What `postCommandDrag` did, for the log.
    struct PostedDrag: Sendable, CustomStringConvertible {
        /// Milliseconds from the mouse-down until the item was seen lifted (nil: never seen).
        var liftedAfter: Int?
        /// Milliseconds from the mouse-down until the mouse-up.
        var releasedAfter: Int
        /// Where the mouse-up was posted, and where it would have gone by the frames read before the drag.
        var mouseUp: CGPoint
        var plannedMouseUp: CGPoint
        /// The user pressed a mouse button meanwhile, so the mouse-up was posted right away.
        var interrupted = false
        /// When the mouse-down was posted, the item was seen lifted, and the mouse-up was posted.
        var downAt: ContinuousClock.Instant?
        var liftedAt: ContinuousClock.Instant?
        var releasedAt: ContinuousClock.Instant?
        /// Where the pointer was before the drag.
        var savedCursor: CGPoint?
        /// For a move out (`CursorDisposition.onMovedItem`): the pointer is still hidden at the drop point; the caller
        /// ends this once the item has landed. nil: the drag already put the pointer back and showed it.
        var concealment: CursorConcealment?
        /// How long the pointer was away from `savedCursor` (hidden), for background moves (ms).
        var awayFor: Int?

        var description: String {
            let lift = liftedAfter.map { "lifted after \($0) ms" } ?? "not seen lifted"
            return "\(lift), released after \(releasedAfter) ms at x \(Int(mouseUp.x)) (planned \(Int(plannedMouseUp.x)))"
                + (interrupted ? ", cut short by the user's mouse button" : "")
                + (awayFor.map { ", pointer away \($0) ms" } ?? "")
        }
    }

    /// Polling while the synthetic mouse button is down (see `DragRelease`): how often, how long to wait for the item
    /// to be lifted (measured: about 20 ms, but a mouse-up 50 ms after the mouse-down still came too early about one
    /// time in four in the VM), and how long the whole drag may take before the mouse-up is posted anyway (the
    /// on-screen slide takes about 0.4 s).
    nonisolated static let dragPollMicroseconds: useconds_t = 10_000
    nonisolated static let liftTimeout: Duration = .milliseconds(600)
    nonisolated static let releaseTimeout: Duration = .milliseconds(1200)

    /// Called on a background thread (it sleeps between events) so Frost's own main thread can handle the events.
    /// Posts the mouse-down on the Frost icon, waits until `release` says the item has been lifted (and, if the target
    /// may slide, that the menu bar has stopped moving), then posts the mouse-up at the target's position at that moment
    /// (`plannedMouseUp`, computed from the frames before the drag, if the item was never seen lifted). Posts nothing if
    /// a mouse button is down right before the mouse-down (`downAt` stays nil), and the mouse-up early if the user
    /// presses a mouse button meanwhile (`interrupted`; also set for a click between two polls, by the HID press count),
    /// so a ⌘-drag never overlaps the user's own for long. The pointer is hidden from before
    /// the mouse-down; with `.restore` it is put back and shown right after the mouse-up, with `.onMovedItem` it stays
    /// hidden at the drop point (`PostedDrag.concealment`) until the caller puts it on the landed item.
    nonisolated static func postCommandDrag(windowID: CGWindowID, mouseDown down: CGPoint, plannedMouseUp: CGPoint,
                                            release: DragRelease, watching known: Set<CGWindowID>,
                                            cursor disposition: CursorDisposition = .restore) -> PostedDrag {
        // Tracked so quitting never exits between the mouse-down and the mouse-up / cursor restore.
        SyntheticEventGate.posting {
            postCommandDragNow(windowID: windowID, mouseDown: down, plannedMouseUp: plannedMouseUp, release: release,
                               watching: known, cursor: disposition)
        }
    }

    private nonisolated static func postCommandDragNow(windowID: CGWindowID, mouseDown down: CGPoint,
                                                       plannedMouseUp: CGPoint, release: DragRelease,
                                                       watching known: Set<CGWindowID>,
                                                       cursor disposition: CursorDisposition) -> PostedDrag {
        let source = CGEventSource(stateID: .hidSystemState)
        // Same as Ice: don't suppress local (the user's) mouse and keyboard events while posting synthetic ones.
        if let session = CGEventSource(stateID: .combinedSessionState) {
            let permit: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents,
                                             .permitSystemDefinedEvents]
            session.setLocalEventsFilterDuringSuppressionState(permit, state: .eventSuppressionStateRemoteMouseDrag)
            session.setLocalEventsFilterDuringSuppressionState(permit, state: .eventSuppressionStateSuppressionInterval)
            session.localEventsSuppressionInterval = 0
        }
        let savedCursor = CGEvent(source: nil)?.location
        var report = PostedDrag(releasedAfter: 0, mouseUp: plannedMouseUp, plannedMouseUp: plannedMouseUp,
                                savedCursor: savedCursor)
        // The last moment to stay out of the user's way: the caller waited for the buttons to be released, but reading
        // the menu bar since took a while. A ⌘-drag posted while a button is down gets mixed up with the user's own
        // click or drag; post nothing (`downAt` stays nil) and let the caller wait and try again.
        let presses = UserMouseButtons.pressCount
        guard !UserMouseButtons.isAnyHeld else { return report }
        let clock = ContinuousClock()
        let hiddenAt = clock.now
        let concealment = CursorConcealment.begin()
        let keepsHidden = !CursorPlacement.restoresRightAfterDrag(disposition)

        func event(_ type: CGEventType, _ point: CGPoint) -> CGEvent? {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { return nil }
            e.flags = .maskCommand
            e.setIntegerValueField(windowIDField, value: Int64(windowID))
            return e
        }
        guard let downEvent = event(.leftMouseDown, down) else {
            concealment.end()
            return report
        }

        let start = clock.now
        func elapsed() -> Int { Int((clock.now - start) / .milliseconds(1)) }
        var release = release
        var up = plannedMouseUp
        downEvent.post(tap: .cgSessionEventTap)
        report.downAt = start
        while true {
            usleep(dragPollMicroseconds)
            let frames = frames(of: StatusWindowParser.windows(withIDs: known))
            let ready = release.observe(frames)
            if release.isLifted, report.liftedAfter == nil {
                report.liftedAfter = elapsed()
                report.liftedAt = clock.now
            }
            if let point = release.dropPoint(in: frames), release.isLifted { up = point }
            if ready { break }
            if UserMouseButtons.isAnyHeld || UserMouseButtons.pressCount != presses {
                report.interrupted = true
                break
            }
            let waited = clock.now - start
            if waited >= releaseTimeout || (!release.isLifted && waited >= liftTimeout) { break }
        }
        report.releasedAfter = elapsed()
        report.mouseUp = up
        event(.leftMouseUp, up)?.post(tap: .cgSessionEventTap)
        report.releasedAt = clock.now
        usleep(20_000)
        // A click that came and went between two polls (or right with the mouse-up) still got mixed up with the drag.
        if UserMouseButtons.pressCount != presses { report.interrupted = true }
        if keepsHidden {
            report.concealment = concealment
        } else {
            concealment.end(warpingTo: savedCursor)
            report.awayFor = Int((clock.now - hiddenAt) / .milliseconds(1))
        }
        return report
    }
}
