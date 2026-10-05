import Testing
import CoreGraphics
@testable import FrostCore

@Suite struct ObscuredCapturePolicyTests {
    typealias Policy = ObscuredCapturePolicy
    typealias Conditions = ObscuredCapturePolicy.Conditions

    let launch = ContinuousClock.now
    /// Past the launch grace.
    var ready: ContinuousClock.Instant { launch + Policy.launchGrace }
    let display = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func item(_ id: CGWindowID, x: CGFloat, onScreen: Bool, title: String = "Item") -> MenuBarItem {
        MenuBarItem(windowID: id, frame: CGRect(x: x, y: 0, width: 30, height: 39), isOnScreen: onScreen,
                    windowTitle: title, bundleID: "test.app", pid: 1, axDescription: nil)
    }

    func policy(obscured: Set<CGWindowID>, at time: ContinuousClock.Instant? = nil) -> Policy {
        var policy = Policy(launchedAt: launch)
        policy.observe(obscured: obscured, visible: [], now: time ?? launch)
        return policy
    }

    // MARK: Detection

    @Test func withoutExpectationsOnlyItemsUnderTheNotchAreObscured() {
        let items = [
            item(1, x: -4000, onScreen: false),  // pushed out by a separator
            item(2, x: 900, onScreen: false),    // under the notch
            item(3, x: 1100, onScreen: true),
        ]
        #expect(Policy.obscured(in: items, expected: nil, displayBounds: display) == [2])
    }

    @Test func expectedItemsOffScreenAreObscuredWhereverTheyAre() {
        // Expanded with every section shown, items that don't fit may also be laid out left of the display.
        let items = [item(1, x: -300, onScreen: false), item(2, x: 900, onScreen: false),
                     item(3, x: 1100, onScreen: true), item(4, x: -5000, onScreen: false)]
        #expect(Policy.obscured(in: items, expected: [1, 2, 3], displayBounds: display) == [1, 2])
    }

    @Test func immovableItemsAreNeverObscured() {
        var clock = item(1, x: 900, onScreen: false, title: "Clock")
        clock = MenuBarItem(windowID: 1, frame: clock.frame, isOnScreen: false, windowTitle: "Clock",
                            bundleID: "com.apple.controlcenter", pid: 1, axDescription: nil)
        #expect(Policy.obscured(in: [clock], expected: [1], displayBounds: display).isEmpty)
    }

    @Test func itemsSeenOnScreenLaterAreForgotten() {
        var policy = policy(obscured: [1, 2])
        policy.observe(obscured: [], visible: [2, 3], now: ready)
        #expect(policy.obscuredItems == [1])
        policy.retain([5])
        #expect(policy.obscuredItems.isEmpty)
    }

    @Test func observingAgainKeepsTheRecord() {
        var policy = policy(obscured: [1])
        policy.record(.failed, for: 1, now: ready)
        policy.observe(obscured: [1], visible: [], now: ready + .seconds(1))
        #expect(policy.records[1]?.failures == 1)
    }

    // MARK: Conditions

    @Test func idleConditionsAllowAnOperationAfterTheLaunchGrace() {
        let policy = policy(obscured: [1])
        let idle = Conditions(sinceLastInput: .seconds(5))
        #expect(policy.skipReason(idle, now: launch + .seconds(3)) == .launching)
        #expect(policy.skipReason(idle, now: ready) == nil)
    }

    @Test(arguments: [
        (Conditions(isShuttingDown: true), Policy.SkipReason.shuttingDown),
        (Conditions(hasPermissions: false), .permissionsMissing),
        (Conditions(isUserAway: true), .away),
        (Conditions(isFrostBarOpen: true), .frostBarOpen),
        (Conditions(isFrostBarBusy: true), .frostBarBusy),
        (Conditions(isEditing: true), .editing),
        (Conditions(isCollapsed: false), .notCollapsed),
        (Conditions(isMoveInFlight: true), .move),
        (Conditions(isPlacingItems: true), .placingItems),
        (Conditions(isMouseButtonHeld: true), .mouseDown),
        (Conditions(isMenuOnScreen: true), .menuOpen),
        (Conditions(isPointerInMenuBar: true), .pointerInMenuBar),
        (Conditions(sinceLastInput: .milliseconds(300)), .recentInput),
    ])
    func everyBusyConditionDefers(conditions: Conditions, reason: Policy.SkipReason) {
        #expect(policy(obscured: [1]).skipReason(conditions, now: ready) == reason)
    }

    @Test func operationsAreSpacedOutAndBackOffAfterFailuresAndInterruptions() {
        var policy = policy(obscured: [1, 2])
        let idle = Conditions()
        policy.record(.captured(changed: nil), for: 1, now: ready)
        #expect(policy.skipReason(idle, now: ready + .seconds(1)) == .spacing)
        #expect(policy.skipReason(idle, now: ready + Policy.spacing) == nil)

        policy.record(.failed, for: 2, now: ready)
        #expect(policy.skipReason(idle, now: ready + .seconds(10)) == .spacing)
        #expect(policy.skipReason(idle, now: ready + Policy.failureSpacing) == nil)

        policy.record(.interrupted, for: 2, now: ready)
        #expect(policy.skipReason(idle, now: ready + .seconds(5)) == .spacing)
        #expect(policy.skipReason(idle, now: ready + Policy.interruptionSpacing) == nil)
    }

    @Test func abortingIgnoresWhatTheOperationCausesItself() {
        // Its own transaction, its own synthetic input, the spacing: not reasons to stop.
        #expect(!Policy.shouldAbort(Conditions(isMoveInFlight: true, sinceLastInput: .zero)))
        #expect(Policy.shouldAbort(Conditions(isFrostBarOpen: true)))
        #expect(Policy.shouldAbort(Conditions(isMouseButtonHeld: true)))
        #expect(Policy.shouldAbort(Conditions(isPointerInMenuBar: true)))
        #expect(Policy.shouldAbort(Conditions(isUserAway: true)))
        #expect(Policy.shouldAbort(Conditions(isShuttingDown: true)))
        #expect(Policy.shouldAbort(Conditions(isEditing: true)))
    }

    // MARK: Choosing items

    @Test func missingCapturesComeFirstOneItemAtATime() {
        let policy = policy(obscured: [1, 2, 3])
        let later = ready + Policy.staleAge
        // 1 has a (possibly stale) capture, 3 has none.
        let next = policy.nextItem(order: [1, 2, 3], needsImage: { $0 == 3 }, now: later)
        #expect(next?.id == 3)
        #expect(next?.need == .missing)
        #expect(policy.nextItem(order: [1, 2, 3], needsImage: { _ in false }, now: later)?.id == 1)
    }

    @Test func itemsThatAreNotObscuredAreNeverChosen() {
        let policy = policy(obscured: [1])
        #expect(policy.nextItem(order: [5, 6], needsImage: { _ in true }, now: ready) == nil)
    }

    @Test func aCachedImageIsCheckedOnceAfterTheStaleAgeAndAStaticItemIsLeftAlone() {
        var policy = policy(obscured: [1], at: launch)
        // Shown from the disk cache: fine for now.
        #expect(policy.nextItem(order: [1], needsImage: { _ in false }, now: ready) == nil)
        #expect(policy.timeUntilNextDue(order: [1], needsImage: { _ in false }, now: ready)
            == Policy.staleAge - Policy.launchGrace)
        let check = launch + Policy.staleAge
        #expect(policy.nextItem(order: [1], needsImage: { _ in false }, now: check)?.need == .refresh)
        policy.record(.captured(changed: false), for: 1, now: check)
        let much = check + Policy.staleAge * 10
        #expect(policy.nextItem(order: [1], needsImage: { _ in false }, now: much) == nil)
        #expect(policy.timeUntilNextDue(order: [1], needsImage: { _ in false }, now: much) == nil)
        // Unless its capture is gone again (e.g. the appearance changed).
        #expect(policy.nextItem(order: [1], needsImage: { _ in true }, now: much)?.need == .missing)
    }

    @Test func aChangingItemIsRefreshedEveryStaleAge() {
        var policy = policy(obscured: [1])
        policy.record(.captured(changed: nil), for: 1, now: ready)
        // First capture: unknown whether it changes; checked once more after the stale age.
        #expect(policy.nextItem(order: [1], needsImage: { _ in false }, now: ready + .seconds(60)) == nil)
        let second = ready + Policy.staleAge
        #expect(policy.nextItem(order: [1], needsImage: { _ in false }, now: second)?.need == .refresh)
        policy.record(.captured(changed: true), for: 1, now: second)
        #expect(policy.nextItem(order: [1], needsImage: { _ in false }, now: second + .seconds(60)) == nil)
        #expect(policy.nextItem(order: [1], needsImage: { _ in false }, now: second + Policy.staleAge)?.need == .refresh)
    }

    @Test func failuresBackOffPerItemAndEventuallyGiveUp() {
        var policy = policy(obscured: [1, 2])
        policy.record(.failed, for: 1, now: ready)
        // 1 waits for its back-off; 2 is still due.
        #expect(policy.nextItem(order: [1, 2], needsImage: { _ in true }, now: ready + .seconds(1))?.id == 2)
        #expect(policy.timeUntilNextDue(order: [1], needsImage: { _ in true }, now: ready) == Policy.retryBase)
        var now = ready
        for _ in 1..<Policy.maxFailures {
            now = now + Policy.retryCap
            #expect(policy.nextItem(order: [1], needsImage: { _ in true }, now: now)?.id == 1)
            policy.record(.failed, for: 1, now: now)
        }
        #expect(policy.nextItem(order: [1], needsImage: { _ in true }, now: now + Policy.retryCap * 10) == nil)
        // A manual refresh tries again.
        policy.reset()
        #expect(policy.nextItem(order: [1], needsImage: { _ in true }, now: now)?.id == 1)
    }

    @Test func aSuccessClearsFailures() {
        var policy = policy(obscured: [1])
        policy.record(.failed, for: 1, now: ready)
        policy.record(.captured(changed: nil), for: 1, now: ready + Policy.retryBase)
        #expect(policy.records[1]?.failures == 0)
        #expect(policy.records[1]?.retryAt == nil)
    }

    @Test func anInterruptedItemIsRetriedSoonWithoutPenalty() {
        var policy = policy(obscured: [1])
        policy.record(.interrupted, for: 1, now: ready)
        #expect(policy.records[1]?.failures == 0)
        #expect(policy.nextItem(order: [1], needsImage: { _ in true }, now: ready + .seconds(1)) == nil)
        #expect(policy.nextItem(order: [1], needsImage: { _ in true }, now: ready + Policy.interruptionSpacing)?.id == 1)
    }

    @Test func notApplicableForgetsTheItem() {
        var policy = policy(obscured: [1])
        policy.record(.notApplicable, for: 1, now: ready)
        #expect(policy.obscuredItems.isEmpty)
    }

    @Test func retryDelayDoublesUpToTheCap() {
        #expect(Policy.retryDelay(afterFailures: 1) == Policy.retryBase)
        #expect(Policy.retryDelay(afterFailures: 2) == Policy.retryBase * 2)
        #expect(Policy.retryDelay(afterFailures: 3) == Policy.retryBase * 4)
        #expect(Policy.retryDelay(afterFailures: 30) == Policy.retryCap)
    }

    // MARK: Freeze frame geometry

    @Test func theShiftingRegionEndsAtTheFrostIconsRightEdge() {
        let strip = CGRect(x: 0, y: 943, width: 1512, height: 39)
        let icon = CGRect(x: 1200, y: 943, width: 30, height: 39)
        #expect(Policy.shiftingRegion(of: strip, iconFrames: [icon]) == CGRect(x: 0, y: 943, width: 1230, height: 39))
        // The icon on another display: not this strip's.
        let other = CGRect(x: 2000, y: 943, width: 30, height: 39)
        #expect(Policy.shiftingRegion(of: strip, iconFrames: [other]) == nil)
    }
}
