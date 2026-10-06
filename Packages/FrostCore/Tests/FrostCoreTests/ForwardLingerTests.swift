import CoreGraphics
import Testing
@testable import FrostCore

@Suite struct ForwardLingerTests {
    /// Fixed timing (the scenarios below are written for a 1 s leave delay), independent of `Timing.standard`.
    static let timing = ForwardLinger.Timing(leaveDelay: .seconds(1), idleCap: .seconds(30), openTimeout: .seconds(1),
                                             presentationCap: .seconds(60))

    let t0 = ContinuousClock.now
    func ms(_ value: Int) -> ContinuousClock.Instant { t0 + .milliseconds(value) }

    func sample(_ time: Int, over: Bool = false, held: Bool = false, clicked: Bool = false, open: Bool = false,
                menu: Bool = false) -> ForwardLinger.Sample {
        ForwardLinger.Sample(time: ms(time), isPointerOverItem: over, isMouseButtonHeld: held, clickedItem: clicked,
                             isPresentationOpen: open, isMenuOpen: menu)
    }

    @Test func pointerAwayRestoresAfterTheLeaveDelay() {
        var linger = ForwardLinger(start: t0, timing: Self.timing)
        #expect(linger.update(sample(100)) == .keep)
        #expect(linger.update(sample(900)) == .keep)
        #expect(linger.update(sample(1000)) == .restore(.pointerLeft))
    }

    @Test func pointerOverTheItemKeepsItOutUntilItLeaves() {
        var linger = ForwardLinger(start: t0, timing: Self.timing)
        #expect(linger.update(sample(500, over: true)) == .keep)
        #expect(linger.update(sample(5000, over: true)) == .keep)
        // Left at 5 s: one more second.
        #expect(linger.update(sample(5100)) == .keep)
        #expect(linger.update(sample(5900)) == .keep)
        #expect(linger.update(sample(6000)) == .restore(.pointerLeft))
    }

    @Test func restingOnTheItemWithoutClickingEndsAtTheIdleCap() {
        var linger = ForwardLinger(start: t0, timing: Self.timing)
        #expect(linger.update(sample(29_900, over: true)) == .keep)
        #expect(linger.update(sample(30_000, over: true)) == .restore(.idle))
    }

    @Test func aClickOnTheItemWaitsForItsMenuToClose() {
        var linger = ForwardLinger(start: t0, timing: Self.timing)
        #expect(linger.update(sample(300, over: true, held: true, clicked: true)) == .keep)
        #expect(!linger.acceptsNewBaseline)
        // The menu appears; the pointer moves down into it (away from the item) for a long time: menus have no cap.
        #expect(linger.update(sample(400, open: true, menu: true)) == .keep)
        #expect(linger.update(sample(120_000, open: true, menu: true)) == .keep)
        // Closed (an entry was picked below the menu bar): back after the leave delay from the close.
        #expect(linger.update(sample(120_100)) == .keep)
        #expect(linger.acceptsNewBaseline)
        #expect(linger.update(sample(121_000)) == .keep)
        #expect(linger.update(sample(121_100)) == .restore(.pointerLeft))
    }

    @Test func aClickThatOpensNothingFallsBackToTheUsualRules() {
        var linger = ForwardLinger(start: t0, timing: Self.timing)
        #expect(linger.update(sample(200, over: true, clicked: true)) == .keep)
        // Pointer leaves right away, but the presentation may still come: keep until the open timeout.
        #expect(linger.update(sample(1100)) == .keep)
        #expect(linger.update(sample(1200)) == .restore(.pointerLeft))
    }

    @Test func aPopoverOpenedFromTheMenuBarIsCapped() {
        var linger = ForwardLinger(start: t0, timing: Self.timing)
        _ = linger.update(sample(100, over: true, clicked: true))
        #expect(linger.update(sample(200, open: true)) == .keep)
        #expect(linger.update(sample(60_100, open: true)) == .keep)
        #expect(linger.update(sample(60_200, open: true)) == .restore(.presentationCap))
    }

    @Test func neverRestoresWhileAButtonIsHeld() {
        var linger = ForwardLinger(start: t0, timing: Self.timing)
        #expect(linger.update(sample(5000, held: true)) == .keep)
        #expect(linger.update(sample(5100)) == .restore(.pointerLeft))
        var resting = ForwardLinger(start: t0, timing: Self.timing)
        #expect(resting.update(sample(40_000, over: true, held: true)) == .keep)
        // A held button on the item is a click starting (the monitor reports it): it restarts the idle time.
        var popover = ForwardLinger(start: t0, timing: Self.timing)
        _ = popover.update(sample(100, clicked: true))
        _ = popover.update(sample(200, open: true))
        #expect(popover.update(sample(70_000, held: true, open: true)) == .keep)
    }

    @Test func clickingAgainWhileOpenKeepsWaitingForTheClose() {
        var linger = ForwardLinger(start: t0, timing: Self.timing)
        _ = linger.update(sample(100, over: true, clicked: true))
        #expect(linger.update(sample(200, over: true, open: true, menu: true)) == .keep)
        // The user clicks the item again: the menu closes.
        #expect(linger.update(sample(3000, over: true, clicked: true, open: true, menu: true)) == .keep)
        #expect(linger.update(sample(3200, over: true)) == .keep)
        // Pointer still on the item: the idle cap counts from the close.
        #expect(linger.update(sample(33_100, over: true)) == .keep)
        #expect(linger.update(sample(33_200, over: true)) == .restore(.idle))
    }

    // MARK: Standard timing and the pointer region

    @Test func theStandardTimingMovesTheItemBackWithinAboutASecondOfLeavingIt() {
        let timing = ForwardLinger.Timing.standard
        #expect(timing.leaveDelay >= .milliseconds(500) && timing.leaveDelay <= .seconds(1))
        var linger = ForwardLinger(start: t0, timing: timing)
        #expect(linger.update(sample(400, over: true)) == .keep)
        // Pointer away from the item (idling elsewhere on the menu bar no longer counts as being on it).
        let left = Int(timing.leaveDelay.components.attoseconds / 1_000_000_000_000_000) + 400
        #expect(linger.update(sample(left - 10)) == .keep)
        #expect(linger.update(sample(left)) == .restore(.pointerLeft))
    }

    @Test func aPointerRestingOnTheItemDoesNotHoldItOutForLong() {
        let timing = ForwardLinger.Timing.standard
        #expect(timing.idleCap <= .seconds(15))
    }

    @Test func thePointerRegionIsTheItemFrameWithASmallMargin() {
        let item = CGRect(x: 100, y: 0, width: 30, height: 24)
        let region = ForwardLinger.pointerRegion(of: item)
        #expect(region.contains(CGPoint(x: 100, y: 12)))
        #expect(region.contains(CGPoint(x: 130 + ForwardLinger.pointerMargin - 1, y: 12)))
        #expect(!region.contains(CGPoint(x: 130 + ForwardLinger.pointerMargin + 1, y: 12)))
        #expect(!region.contains(CGPoint(x: 100 - ForwardLinger.pointerMargin - 1, y: 12)))
        // Not the whole menu bar row: a point far to either side is outside.
        #expect(!region.contains(CGPoint(x: 600, y: 12)))
        #expect(!region.contains(CGPoint(x: 10, y: 12)))
    }
}
