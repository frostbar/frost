import CoreGraphics

/// Scheduling rules for the background "capture by moving out" of items that never become visible, even with every
/// section expanded (squeezed behind the notch on a crowded notched display).
///
/// macOS doesn't render such items (`isOnScreen == false` even when expanded), so ScreenCaptureKit can't capture them
/// (−3811) and the Frost Bar and the layout editor would show their app icon forever. Every item can be captured right
/// of the Frost icon, though: that slot is always visible. So, in the background and under a freeze frame of the whole
/// menu bar, Frost moves one such item right of the Frost icon, captures it, and moves it back to its exact slot (the
/// app layer's `FrostBarController+ObscuredCapture`). This type holds only the pure decisions:
///
/// - **Which items**: those an expanded or editing scan saw off screen although that state shows their section
///   (`obscured(in:expected:displayBounds:)`), and that have no current capture: none at all, or one that may be out
///   of date (`staleAge`). Whether an item's image changes is learned from successive captures: an item captured once
///   (or shown from the disk cache) is captured once more after `staleAge`; if that capture is identical, the item
///   counts as static and isn't captured again this run, otherwise it is refreshed every `staleAge`.
/// - **When**: only while nothing else touches the menu bar and the user isn't using it (`skipReason`), never during the
///   first `launchGrace` after launch, one item per operation, at least `spacing` between operations (longer after a
///   failure or an interruption), with a growing per-item back-off after failures (`retryDelay`), giving up on an item
///   for this run after `maxFailures`.
public struct ObscuredCapturePolicy: Sendable {
    public typealias Instant = ContinuousClock.Instant

    /// No operation in the first seconds after launch (the scan, ownership, the disk cache and the Frost Bar's warm-up
    /// are still settling, and the user may be logging in).
    public static let launchGrace: Duration = .seconds(20)
    /// From the end of one operation to the start of the next.
    public static let spacing: Duration = .seconds(2)
    /// After a failed operation (any item).
    public static let failureSpacing: Duration = .seconds(30)
    /// After an operation the user interrupted (pointer into the menu bar, a click, the Frost Bar opening).
    public static let interruptionSpacing: Duration = .seconds(10)
    /// A capture older than this may be out of date (only for items whose image changes, see the type's documentation).
    public static let staleAge: Duration = .seconds(10 * 60)
    /// Per-item back-off after a failure: `retryBase` doubled per consecutive failure, at most `retryCap`.
    public static let retryBase: Duration = .seconds(60)
    public static let retryCap: Duration = .seconds(30 * 60)
    /// Consecutive failures after which an item isn't tried again in this run (until `reset`).
    public static let maxFailures = 4
    /// The user must not have touched the mouse or keyboard for this long (their pointer would be put back where it
    /// was before the move, undoing what they just did with it).
    public static let inputIdle: Duration = .seconds(1)
    /// How often to check again while an operation is due but must wait.
    public static let recheck: Duration = .seconds(1)

    /// Everything that decides whether an operation may start now (collected by the app layer).
    public struct Conditions: Equatable, Sendable {
        /// Accessibility (moving) and Screen Recording (capturing).
        public var hasPermissions: Bool
        public var isUserAway: Bool
        public var isShuttingDown: Bool
        public var isFrostBarOpen: Bool
        /// A click forward, a move-back retry or a live refresh round hasn't finished yet.
        public var isFrostBarBusy: Bool
        public var isEditing: Bool
        /// Moves need the collapsed state: expanded, obscured items' positions are unreliable.
        public var isCollapsed: Bool
        /// An `ItemMover` transaction is in progress.
        public var isMoveInFlight: Bool
        /// New-item placement / section memory has a decision pending or running.
        public var isPlacingItems: Bool
        /// A mouse button is held (HID state).
        public var isMouseButtonHeld: Bool
        /// A menu is open (the ⌘-drag's mouse-down would close it).
        public var isMenuOnScreen: Bool
        /// The pointer is over a menu bar (items there will shift under it).
        public var isPointerInMenuBar: Bool
        /// Time since the user's last mouse / keyboard input (nil = unknown).
        public var sinceLastInput: Duration?

        public init(hasPermissions: Bool = true, isUserAway: Bool = false, isShuttingDown: Bool = false,
                    isFrostBarOpen: Bool = false, isFrostBarBusy: Bool = false, isEditing: Bool = false,
                    isCollapsed: Bool = true, isMoveInFlight: Bool = false, isPlacingItems: Bool = false,
                    isMouseButtonHeld: Bool = false, isMenuOnScreen: Bool = false, isPointerInMenuBar: Bool = false,
                    sinceLastInput: Duration? = nil) {
            self.hasPermissions = hasPermissions
            self.isUserAway = isUserAway
            self.isShuttingDown = isShuttingDown
            self.isFrostBarOpen = isFrostBarOpen
            self.isFrostBarBusy = isFrostBarBusy
            self.isEditing = isEditing
            self.isCollapsed = isCollapsed
            self.isMoveInFlight = isMoveInFlight
            self.isPlacingItems = isPlacingItems
            self.isMouseButtonHeld = isMouseButtonHeld
            self.isMenuOnScreen = isMenuOnScreen
            self.isPointerInMenuBar = isPointerInMenuBar
            self.sinceLastInput = sinceLastInput
        }
    }

    /// Why an operation can't start now (the first that holds, in this order).
    public enum SkipReason: String, Sendable, CaseIterable {
        case shuttingDown, permissionsMissing, away, launching, spacing, frostBarOpen, frostBarBusy, editing,
             notCollapsed, move, placingItems, mouseDown, menuOpen, pointerInMenuBar, recentInput
    }

    /// Why an item is due.
    public enum Need: String, Sendable {
        /// No capture at all (the app icon is shown).
        case missing
        /// Its capture may be out of date.
        case refresh
    }

    /// How an operation ended.
    public enum Outcome: Sendable, Equatable {
        /// Captured. `changed`: the new capture differs from the one shown before (nil: there was none).
        case captured(changed: Bool?)
        /// Something failed (the move, the capture, or moving back): back off.
        case failed
        /// The user (or Frost) needed the menu bar meanwhile: try again a little later, no penalty.
        case interrupted
        /// Nothing was done (e.g. the item turned out to be in the Visible section): forget the item.
        case notApplicable
    }

    struct Record: Equatable, Sendable {
        /// When it was first seen obscured.
        var seenAt: Instant
        /// When this policy last captured it (nil: never in this run).
        var capturedAt: Instant?
        /// Whether its image changes (nil: unknown).
        var isDynamic: Bool?
        var failures = 0
        var retryAt: Instant?
    }

    private let launchedAt: Instant
    private(set) var records: [CGWindowID: Record] = [:]
    private var lastEnd: Instant?
    private var lastOutcome: Outcome?

    public init(launchedAt: Instant) {
        self.launchedAt = launchedAt
    }

    /// The items currently known to be obscured.
    public var obscuredItems: Set<CGWindowID> { Set(records.keys) }

    // MARK: - Observations

    /// Items of an expanded or editing scan that are off screen although that state shows them. `expected`: the items
    /// the state shows (e.g. the Frost Bar's requested items during a temporary expansion, every item while editing);
    /// nil when unknown, then only items under the notch (`ItemMover.isObscured`: off screen with a frame reaching into
    /// the display; items pushed out by a separator lie entirely left of it). Immovable items (the clock, Control Center)
    /// are never included.
    public static func obscured(in items: [MenuBarItem], expected: Set<CGWindowID>?,
                                displayBounds: CGRect) -> Set<CGWindowID> {
        Set(items.filter { item in
            guard !item.isOnScreen, item.isMovable else { return false }
            if let expected { return expected.contains(item.windowID) }
            return ItemMover.isObscured(item, displayBounds: displayBounds)
        }.map(\.windowID))
    }

    /// Records an expanded / editing scan: `obscured` items are candidates from now on; items in `visible` (on screen
    /// in that scan) aren't (any more): ordinary captures handle them.
    public mutating func observe(obscured: Set<CGWindowID>, visible: Set<CGWindowID>, now: Instant) {
        for id in visible where !obscured.contains(id) { records[id] = nil }
        for id in obscured where records[id] == nil { records[id] = Record(seenAt: now) }
    }

    /// Forgets items that are no longer in the menu bar (their app quit; window IDs aren't reused for the same item).
    public mutating func retain(_ existing: Set<CGWindowID>) {
        records = records.filter { existing.contains($0.key) }
    }

    /// Forgets failures and back-offs (the user asked for a refresh).
    public mutating func reset() {
        for id in records.keys {
            records[id]?.failures = 0
            records[id]?.retryAt = nil
        }
        if lastOutcome == .failed { lastOutcome = nil }
    }

    // MARK: - Decisions

    /// nil = an operation may start now.
    public func skipReason(_ c: Conditions, now: Instant) -> SkipReason? {
        if c.isShuttingDown { return .shuttingDown }
        if !c.hasPermissions { return .permissionsMissing }
        if c.isUserAway { return .away }
        if now - launchedAt < Self.launchGrace { return .launching }
        if let lastEnd, now - lastEnd < spacingAfterLastOperation { return .spacing }
        if c.isFrostBarOpen { return .frostBarOpen }
        if c.isFrostBarBusy { return .frostBarBusy }
        if c.isEditing { return .editing }
        if !c.isCollapsed { return .notCollapsed }
        if c.isMoveInFlight { return .move }
        if c.isPlacingItems { return .placingItems }
        if c.isMouseButtonHeld { return .mouseDown }
        if c.isMenuOnScreen { return .menuOpen }
        if c.isPointerInMenuBar { return .pointerInMenuBar }
        if let idle = c.sinceLastInput, idle < Self.inputIdle { return .recentInput }
        return nil
    }

    /// Whether an operation in progress must stop now (no capture; move the item back right away). Same conditions as
    /// starting one, except the ones the operation itself causes (its own move transaction, the spacing, the launch
    /// grace, recent input: its own synthetic events count as input).
    public static func shouldAbort(_ c: Conditions) -> Bool {
        c.isShuttingDown || !c.hasPermissions || c.isUserAway || c.isFrostBarOpen || c.isFrostBarBusy || c.isEditing
            || c.isMouseButtonHeld || c.isMenuOnScreen || c.isPointerInMenuBar
    }

    private var spacingAfterLastOperation: Duration {
        switch lastOutcome {
        case .failed: Self.failureSpacing
        case .interrupted: Self.interruptionSpacing
        default: Self.spacing
        }
    }

    /// Why `id` is due now, or nil. `needsImage`: it has no current capture (none, or one from another appearance).
    func need(_ id: CGWindowID, needsImage: Bool, now: Instant) -> Need? {
        guard let record = records[id], record.failures < Self.maxFailures else { return nil }
        if let retryAt = record.retryAt, now < retryAt { return nil }
        if needsImage { return .missing }
        if record.isDynamic == false { return nil }
        let since = record.capturedAt ?? record.seenAt
        return now - since >= Self.staleAge ? .refresh : nil
    }

    /// The item to capture next: missing captures first, then refreshes, each in `order` (e.g. left to right); nil when
    /// nothing is due. `needsImage(id)`: the item has no current capture.
    public func nextItem(order: [CGWindowID], needsImage: (CGWindowID) -> Bool,
                         now: Instant) -> (id: CGWindowID, need: Need)? {
        let due = order.compactMap { id in need(id, needsImage: needsImage(id), now: now).map { (id: id, need: $0) } }
        return due.first { $0.need == .missing } ?? due.first
    }

    /// How long until some item becomes due (zero: one is due now; nil: none will be without a new observation or a
    /// change of its image). Doesn't include `skipReason` waits.
    public func timeUntilNextDue(order: [CGWindowID], needsImage: (CGWindowID) -> Bool, now: Instant) -> Duration? {
        var earliest: Duration?
        for id in order {
            guard let record = records[id], record.failures < Self.maxFailures else { continue }
            var due: Instant
            if needsImage(id) {
                due = now
            } else if record.isDynamic == false {
                continue
            } else {
                due = (record.capturedAt ?? record.seenAt) + Self.staleAge
            }
            if let retryAt = record.retryAt, retryAt > due { due = retryAt }
            let wait = max(.zero, due - now)
            earliest = min(earliest ?? wait, wait)
        }
        return earliest
    }

    /// Records how the operation on `id` ended at `now`.
    public mutating func record(_ outcome: Outcome, for id: CGWindowID, now: Instant) {
        lastEnd = now
        lastOutcome = outcome
        switch outcome {
        case .captured(let changed):
            guard var record = records[id] else { return }
            record.capturedAt = now
            record.failures = 0
            record.retryAt = nil
            // Compared with an earlier capture: now we know whether it changes. Without one (the first capture filled a
            // missing image) it's still unknown, so it's captured once more after `staleAge`.
            if let changed { record.isDynamic = changed }
            records[id] = record
        case .failed:
            guard var record = records[id] else { return }
            record.failures += 1
            record.retryAt = now + Self.retryDelay(afterFailures: record.failures)
            records[id] = record
        case .interrupted:
            records[id]?.retryAt = now + Self.interruptionSpacing
        case .notApplicable:
            records[id] = nil
        }
    }

    /// What capturing the moved-out item did in one operation (from this round's own result, never from the cache: a
    /// failed capture leaves the previous image in place).
    public enum CaptureAttempt: Sendable, Equatable {
        /// Not captured: interrupted before, or the move out failed.
        case notAttempted
        /// The appearance changed during the capture and its result was thrown away.
        case discarded
        /// ScreenCaptureKit returned nothing usable (an error, or a blank image).
        case failed
        /// Captured; `changed`: the pixels differ from the image stored before.
        case succeeded(changed: Bool)
    }

    /// How an operation ended. `hadPrevious`: a current image was compared with (nil `changed` without one: the first
    /// capture of a missing image tells nothing about whether it changes). `moveFailed`: moving it out or back failed.
    public static func outcome(of capture: CaptureAttempt, hadPrevious: Bool, moveFailed: Bool) -> Outcome {
        switch capture {
        case .succeeded(let changed): .captured(changed: hadPrevious ? changed : nil)
        case .failed: .failed
        case .discarded: moveFailed ? .failed : .interrupted
        case .notAttempted: moveFailed ? .failed : .interrupted
        }
    }

    /// Back-off after `failures` consecutive failures (1 = the first): `retryBase` doubled per failure, capped.
    public static func retryDelay(afterFailures failures: Int) -> Duration {
        let doublings = max(0, min(failures - 1, 16))
        return min(retryBase * (1 << doublings), retryCap)
    }

    // MARK: - Freeze frame geometry

    /// The part of a menu bar strip whose contents shift while an item sits right of the Frost icon: the strip from its
    /// left edge to the icon's right edge (the menu bar is right-aligned, so the moved item, the icon and everything left
    /// of it shift left; nothing right of the icon moves). Clicks there would hit a different item than the one shown,
    /// so the freeze frame intercepts them; the rest of the strip stays click-through. nil when no icon lies in the
    /// strip (cover it all as interactive). Same coordinate space as the arguments.
    public static func shiftingRegion(of strip: CGRect, iconFrames: [CGRect]) -> CGRect? {
        guard let icon = iconFrames.first(where: { icon in
            strip.minX <= icon.midX && icon.midX < strip.maxX && strip.minY <= icon.midY && icon.midY <= strip.maxY
        }) else { return nil }
        var region = strip
        region.size.width = max(0, min(icon.maxX, strip.maxX) - strip.minX)
        return region
    }
}
