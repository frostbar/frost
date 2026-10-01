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
}

/// Moves menu bar items with a synthetic ⌘-drag (implemented per spike-findings.md, "Task 11").
///
/// - Every event sets field `0x33 = dragged item's windowID`, so the system routes by windowID rather than by
///   cursor position.
/// - The mouse-down physically lands on the center of the Frost icon: it is always visible and is Frost's own
///   item. Even if routing degrades to position-based, the worst case is dragging Frost's own icon, never a
///   third-party icon. This is also why off-screen items (pushed off / under the notch) can be moved.
/// - No dragged events: down → 50 ms → up. The drop position is determined by the mouseUp's raw coordinates
///   (which may be off screen).
@MainActor
public final class ItemMover {
    private let scanner: MenuBarItemScanner

    /// Window IDs of Frost's three controls, injected by the app layer (`FrostControlLocator`). `move` uses the
    /// icon as the mouse-down position.
    public var controlWindows: () -> FrostControlWindows? = { nil }

    public var maxAttempts = 3
    /// Delay after posting events before the first check; then poll every `pollInterval` until the order is
    /// correct and frames are stable, for at most `settleTimeout`.
    /// Measured: the order is correct after 32–40 ms; on-screen move animations finish in 390–540 ms, moves
    /// between off-screen positions in 94–152 ms.
    public var initialSettleDelay: Duration = .milliseconds(50)
    public var pollInterval: Duration = .milliseconds(25)
    public var settleTimeout: Duration = .seconds(1)

    /// Whether a move transaction is in progress. `@MainActor` only prevents concurrent access; it doesn't keep a
    /// whole transaction spanning awaits from being interleaved, so every move (including Frost Bar's entire
    /// "move out → click → move back" flow) must be wrapped in `transaction`.
    public private(set) var isBusy = false

    /// Frost is quitting (`beginShutdown`): new transactions throw `.shuttingDown` unless they are the move-back
    /// work quitting itself runs, and every move gets at most `shutdownMaxAttempts` attempts so quitting stays
    /// responsive.
    public private(set) var isShuttingDown = false
    /// Attempts per move once shutting down (instead of `maxAttempts`).
    public var shutdownMaxAttempts = 1

    public init(scanner: MenuBarItemScanner) { self.scanner = scanner }

    /// Runs a move transaction exclusively; throws `.busy` immediately if one is already in progress (the caller
    /// decides: the layout editor and the Frost Bar click forward wait for `isBusy` to become false first, see
    /// `waitUntilIdle`). Once shutting down, throws `.shuttingDown` unless `allowedDuringShutdown` (moving an icon
    /// back to its section while quitting).
    public func transaction<T>(allowedDuringShutdown: Bool = false, _ body: () async throws -> T) async throws -> T {
        guard !isShuttingDown || allowedDuringShutdown else { throw ItemMoveError.shuttingDown }
        guard !isBusy else { throw ItemMoveError.busy }
        isBusy = true
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
    public func move(_ itemID: CGWindowID, to destination: MoveDestination) async throws {
        try await move(itemID, to: destination, attempts: maxAttempts, checkingControls: true)
    }

    /// - `checkingControls`: after each attempt, check the order of Frost's controls (see `controlsInOrder`); if
    ///   disturbed, move the icon back to `.rightOf(H)` once and throw `.controlsDisturbed` (no further retries:
    ///   retrying would just keep dragging the icon).
    private func move(_ itemID: CGWindowID, to destination: MoveDestination, attempts: Int,
                      checkingControls: Bool) async throws {
        assert(isBusy, "ItemMover.move must be called inside transaction")
        for attempt in 1...max(1, attempts) {
            try Task.checkCancellation()
            // Quitting began during this move: stop retrying (checked per attempt, so a move that was already
            // retrying finishes its current attempt and then gives up).
            guard attempt <= Self.attemptLimit(requested: attempts, isShuttingDown: isShuttingDown,
                                               shutdownLimit: shutdownMaxAttempts) else { break }
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
            await Task.detached { Self.postCommandDrag(windowID: itemID, mouseDown: down, mouseUp: up) }.value

            let known = Set(frames.keys)
            let result = try await Self.waitForSettle(
                initialDelay: initialSettleDelay, interval: pollInterval, timeout: settleTimeout,
                snapshot: { Self.frames(of: StatusWindowParser.windows(withIDs: known)) },
                satisfied: { Self.isSatisfied(itemID, destination, frames: $0) })
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
        }
        throw ItemMoveError.didNotMove
    }

    /// Bounds of the display hosting the scanned menu bar (the active menu bar, not necessarily the main
    /// display); needed to decide what is "under the notch".
    private var menuBarDisplayBounds: CGRect {
        scanner.menuBarDisplay?.frame ?? CGDisplayBounds(CGMainDisplayID())
    }

    // MARK: - Pure logic (unit tested)

    /// How many attempts a move may make: `requested`, capped at `shutdownLimit` while shutting down; at least one.
    nonisolated static func attemptLimit(requested: Int, isShuttingDown: Bool, shutdownLimit: Int) -> Int {
        max(1, isShuttingDown ? min(requested, shutdownLimit) : requested)
    }

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

    /// Called on a background thread (it uses `usleep`) so Frost's own main thread can handle the events. The
    /// cursor is restored afterwards.
    nonisolated static func postCommandDrag(windowID: CGWindowID, mouseDown down: CGPoint, mouseUp up: CGPoint) {
        // Tracked so quitting never exits between the mouse-down and the mouse-up / cursor restore.
        SyntheticEventGate.posting { postCommandDragNow(windowID: windowID, mouseDown: down, mouseUp: up) }
    }

    private nonisolated static func postCommandDragNow(windowID: CGWindowID, mouseDown down: CGPoint,
                                                       mouseUp up: CGPoint) {
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
        defer { if let savedCursor { CGWarpMouseCursorPosition(savedCursor) } }

        func event(_ type: CGEventType, _ point: CGPoint) -> CGEvent? {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { return nil }
            e.flags = .maskCommand
            e.setIntegerValueField(windowIDField, value: Int64(windowID))
            return e
        }
        guard let downEvent = event(.leftMouseDown, down), let upEvent = event(.leftMouseUp, up) else { return }
        downEvent.post(tap: .cgSessionEventTap)
        usleep(50_000)
        upEvent.post(tap: .cgSessionEventTap)
        usleep(20_000)
    }
}
