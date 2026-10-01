import Testing
import CoreGraphics
@testable import FrostCore

@Suite struct OutsideClickDismissalTests {
    // The popover is below the menu bar, the item is on the menu bar (CG coordinates, top-left origin).
    let popover = CGRect(x: 1369, y: 31, width: 226, height: 106)
    let item = CGRect(x: 1460, y: 0, width: 29, height: 30)
    let ownerMainWindow = CGRect(x: 100, y: 200, width: 600, height: 400)
    let t0 = ContinuousClock.now

    func ms(_ value: Int) -> ContinuousClock.Instant { t0 + .milliseconds(value) }

    /// Mouse down at `point`; by default the target app is not frontmost.
    func click(_ d: inout OutsideClickDismissal, _ point: CGPoint, at time: Int, ownerIsActive: Bool = false) {
        d.mouseDown(at: point, time: ms(time), presentationFrames: [popover], itemFrame: item,
                    ownerWindowFrames: [ownerMainWindow], ownerIsActive: ownerIsActive)
    }

    let outside = CGPoint(x: 800, y: 700)
    let inside = CGPoint(x: 1400, y: 60)

    @Test func outsideMeansNotInAnyPresentationWindowNorTheItem() {
        #expect(OutsideClickDismissal.isOutside(CGPoint(x: 10, y: 10), presentationFrames: [popover], itemFrame: item))
        #expect(!OutsideClickDismissal.isOutside(CGPoint(x: 1400, y: 60), presentationFrames: [popover], itemFrame: item))
        // Clicking the item itself: the user toggles it closed, handled by the app.
        #expect(!OutsideClickDismissal.isOutside(CGPoint(x: 1470, y: 10), presentationFrames: [popover], itemFrame: item))
        // Child windows opened by the popover (e.g. its dropdown menu) count as part of the presentation.
        let child = CGRect(x: 1500, y: 120, width: 200, height: 300)
        #expect(!OutsideClickDismissal.isOutside(CGPoint(x: 1650, y: 350), presentationFrames: [popover, child],
                                                 itemFrame: item))
        // With the item frame unknown, only the presentation is considered.
        #expect(OutsideClickDismissal.isOutside(CGPoint(x: 1470, y: 10), presentationFrames: [popover], itemFrame: nil))
        // The right / bottom edges are not inside the rect (CGRect.contains is half-open).
        #expect(OutsideClickDismissal.isOutside(CGPoint(x: popover.maxX, y: 60), presentationFrames: [popover],
                                                itemFrame: nil))
    }

    @Test func convertsAppKitPointsToCGCoordinates() {
        // Main display is 1117 tall: AppKit y = 1117 (top edge) → CG y = 0; AppKit y = 0 (bottom edge) → CG y = 1117.
        #expect(OutsideClickDismissal.cgPoint(fromAppKit: CGPoint(x: 5, y: 1117), primaryScreenMaxY: 1117)
            == CGPoint(x: 5, y: 0))
        #expect(OutsideClickDismissal.cgPoint(fromAppKit: CGPoint(x: 5, y: 0), primaryScreenMaxY: 1117)
            == CGPoint(x: 5, y: 1117))
        // A secondary display below the main one: negative AppKit y → CG y beyond the main display's height.
        #expect(OutsideClickDismissal.cgPoint(fromAppKit: CGPoint(x: 5, y: -100), primaryScreenMaxY: 1117)
            == CGPoint(x: 5, y: 1217))
    }

    @Test func appliesOnlyToKnownThirdPartyOwners() {
        #expect(OutsideClickDismissal.applies(ownerPID: 500, bundleID: "dev.frost.FakeItems"))
        #expect(OutsideClickDismissal.applies(ownerPID: 500, bundleID: nil))
        #expect(!OutsideClickDismissal.applies(ownerPID: nil, bundleID: "dev.frost.FakeItems"))
        #expect(!OutsideClickDismissal.applies(ownerPID: 500, bundleID: "com.apple.controlcenter"))
        #expect(!OutsideClickDismissal.applies(ownerPID: 500, bundleID: "com.apple.Spotlight"))
    }

    @Test func doesNothingWithoutAnOutsideClick() {
        var d = OutsideClickDismissal()
        #expect(d.poll(now: ms(5000), isFading: false, ownerIsActive: true) == .none)
        click(&d, inside, at: 0)
        click(&d, CGPoint(x: 1470, y: 10), at: 10) // clicking the item itself
        #expect(d.phase == .idle)
        #expect(d.poll(now: ms(5000), isFading: false, ownerIsActive: true) == .none)
    }

    @Test func escalatesEscapeThenItemClickThenGivesUp() {
        var d = OutsideClickDismissal()
        click(&d, outside, at: 0)
        #expect(d.phase == .outsideClick(at: ms(0), grace: .milliseconds(300)))
        #expect(d.poll(now: ms(150), isFading: false, ownerIsActive: true) == .none)
        #expect(d.poll(now: ms(300), isFading: false, ownerIsActive: true) == .sendEscape)
        #expect(d.poll(now: ms(450), isFading: false, ownerIsActive: true) == .none)
        #expect(d.poll(now: ms(900), isFading: false, ownerIsActive: true) == .none)
        #expect(d.poll(now: ms(1000), isFading: false, ownerIsActive: true) == .clickItem)
        #expect(d.poll(now: ms(1500), isFading: false, ownerIsActive: true) == .none)
        #expect(d.poll(now: ms(2000), isFading: false, ownerIsActive: true) == .giveUp)
        #expect(d.phase == .finished)
        #expect(d.poll(now: ms(9000), isFading: false, ownerIsActive: true) == .none)
    }

    @Test func eachActionIsIssuedOnce() {
        var d = OutsideClickDismissal()
        click(&d, outside, at: 0)
        let actions = stride(from: 0, through: 5000, by: 50).map { d.poll(now: ms($0), isFading: false, ownerIsActive: true) }
        #expect(actions.filter { $0 != .none } == [.sendEscape, .clickItem, .giveUp])
    }

    @Test func waitsLongerWhenTheOwnerWillCloseItItself() {
        // The target app is frontmost: the transient popover closes by itself (its window disappears after about
        // 0.5 s), so don't jump in with Esc.
        var active = OutsideClickDismissal()
        click(&active, outside, at: 0, ownerIsActive: true)
        #expect(active.poll(now: ms(600), isFading: false, ownerIsActive: true) == .none)
        #expect(active.poll(now: ms(1000), isFading: false, ownerIsActive: true) == .sendEscape)

        // Clicking another of the app's own windows: this real click activates it, so the longer grace applies as
        // well.
        var ownWindow = OutsideClickDismissal()
        click(&ownWindow, CGPoint(x: 300, y: 300), at: 0)
        #expect(ownWindow.phase == .outsideClick(at: ms(0), grace: .seconds(1)))
    }

    @Test func clickingBackIntoThePresentationDuringGraceCancels() {
        var d = OutsideClickDismissal()
        click(&d, outside, at: 0)
        click(&d, inside, at: 100)
        #expect(d.phase == .idle)
        #expect(d.poll(now: ms(1000), isFading: false, ownerIsActive: true) == .none)
        // Another outside click afterwards: the timer restarts.
        click(&d, outside, at: 2000)
        #expect(d.poll(now: ms(2200), isFading: false, ownerIsActive: true) == .none)
        #expect(d.poll(now: ms(2300), isFading: false, ownerIsActive: true) == .sendEscape)
    }

    @Test func repeatedOutsideClicksDoNotExtendTheGrace() {
        var d = OutsideClickDismissal()
        click(&d, outside, at: 0)
        click(&d, outside, at: 250)
        #expect(d.poll(now: ms(300), isFading: false, ownerIsActive: true) == .sendEscape)
    }

    @Test func clicksAfterEscalationStartedAreIgnored() {
        var d = OutsideClickDismissal()
        click(&d, outside, at: 0)
        #expect(d.poll(now: ms(300), isFading: false, ownerIsActive: true) == .sendEscape)
        click(&d, inside, at: 400)
        #expect(d.phase == .escapeSent(at: ms(300)))
    }

    @Test func neverEscalatesWhileThePresentationIsFadingOut() {
        var d = OutsideClickDismissal()
        click(&d, outside, at: 0)
        // Already closing (fading out): no Esc.
        #expect(d.poll(now: ms(400), isFading: true, ownerIsActive: true) == .none)
        #expect(d.poll(now: ms(500), isFading: false, ownerIsActive: true) == .sendEscape)
        // Esc took effect and it's fading out: must not click the item again (that would reopen it).
        #expect(d.poll(now: ms(1300), isFading: true, ownerIsActive: true) == .none)
        #expect(d.poll(now: ms(1400), isFading: false, ownerIsActive: true) == .clickItem)
        // The toggle click took effect and it's fading out: don't give up, wait for it to disappear.
        #expect(d.poll(now: ms(2500), isFading: true, ownerIsActive: true) == .none)
        #expect(d.poll(now: ms(2600), isFading: false, ownerIsActive: true) == .giveUp)
    }

    @Test func inactiveOwnerSkipsEscapeAndTogglesRightAfterTheGrace() {
        // Hand-off skipped (Frost's settings window is open): the target app isn't frontmost, its popover isn't key,
        // and Esc would be ignored.
        var d = OutsideClickDismissal()
        click(&d, outside, at: 0)
        #expect(d.poll(now: ms(150), isFading: false, ownerIsActive: false) == .none)
        #expect(d.poll(now: ms(300), isFading: false, ownerIsActive: false) == .clickItem)
        #expect(d.phase == .itemClicked(at: ms(300)))
        // The toggle click took effect and it's fading out: no more actions, wait for it to disappear.
        #expect(d.poll(now: ms(450), isFading: true, ownerIsActive: false) == .none)
        #expect(d.poll(now: ms(1250), isFading: true, ownerIsActive: false) == .none)
        // Never closed: give up after toggleWait.
        #expect(d.poll(now: ms(1300), isFading: false, ownerIsActive: false) == .giveUp)
        let actions = { () -> [OutsideClickDismissal.Action] in
            var e = OutsideClickDismissal()
            click(&e, outside, at: 0)
            return stride(from: 0, through: 5000, by: 50).map { e.poll(now: ms($0), isFading: false, ownerIsActive: false) }
        }()
        #expect(actions.filter { $0 != .none } == [.clickItem, .giveUp])
    }

    @Test func neverTogglesAPopoverThatIsAlreadyClosingItself() {
        // The target app isn't frontmost, but it is closing the popover itself (e.g. via a global mouse monitor): it
        // is already fading out within the grace period → don't click.
        var d = OutsideClickDismissal()
        click(&d, outside, at: 0)
        #expect(d.poll(now: ms(300), isFading: true, ownerIsActive: false) == .none)
        #expect(d.poll(now: ms(450), isFading: true, ownerIsActive: false) == .none)
        #expect(d.phase == .outsideClick(at: ms(0), grace: .milliseconds(300)))
    }

    @Test func escapeIsKeptWhenTheOwnerIsActive() {
        // Hand-off succeeded (target app frontmost, popover is key) but the click landed somewhere that doesn't make
        // it resign active, like the Dock: Esc works, so send Esc first.
        var d = OutsideClickDismissal()
        click(&d, outside, at: 0, ownerIsActive: true)
        #expect(d.poll(now: ms(1000), isFading: false, ownerIsActive: true) == .sendEscape)
        // The app resigned active after Esc was sent: still follow the original flow, wait escapeWait then click, no
        // repeats.
        #expect(d.poll(now: ms(1300), isFading: false, ownerIsActive: false) == .none)
        #expect(d.poll(now: ms(1700), isFading: false, ownerIsActive: false) == .clickItem)
    }

    @Test func activationStateIsSampledWhenTheGraceEnds() {
        // The target app was frontmost at the outside click (long grace) but no longer is when the grace ends: click
        // directly, no Esc.
        var d = OutsideClickDismissal()
        click(&d, outside, at: 0, ownerIsActive: true)
        #expect(d.poll(now: ms(1000), isFading: false, ownerIsActive: false) == .clickItem)
    }

    @Test func escapeWaitOutlastsThePopoverFadeOut() {
        // After a popover closes its window takes about 0.5 s to leave CGWindowList: wait longer than that after Esc
        // before clicking the item.
        let timing = OutsideClickDismissal.Timing.standard
        #expect(timing.escapeWait > .milliseconds(500))
        #expect(timing.ownerHandlesGrace > .milliseconds(500))
        #expect(timing.grace == .milliseconds(300))
    }

    // MARK: - Deferring while the user is busy

    @Test func defersEscapeWhileAMouseButtonIsHeld() {
        // The user is drag-selecting (or still holding the outside click): an Esc now could cancel what they are
        // doing. Wait, keeping the phase, and send it once the button is released.
        var d = OutsideClickDismissal()
        click(&d, outside, at: 0)
        // Within the grace period nothing is due, so nothing is being deferred yet.
        #expect(d.poll(now: ms(100), isFading: false, ownerIsActive: true, isMouseButtonPressed: true) == .none)
        #expect(!d.isDeferring)
        #expect(d.poll(now: ms(300), isFading: false, ownerIsActive: true, isMouseButtonPressed: true) == .none)
        #expect(d.isDeferring)
        #expect(d.phase == .outsideClick(at: ms(0), grace: .milliseconds(300)))
        #expect(d.poll(now: ms(2000), isFading: false, ownerIsActive: true, isMouseButtonPressed: true) == .none)
        #expect(d.poll(now: ms(2100), isFading: false, ownerIsActive: true) == .sendEscape)
        #expect(!d.isDeferring)
    }

    @Test func defersTheToggleClickWhileAnotherMenuIsOpen() {
        // The outside click opened another app's menu: a toggle click (mouse-up, warp, click) would close it.
        var d = OutsideClickDismissal()
        click(&d, outside, at: 0)
        #expect(d.poll(now: ms(300), isFading: false, ownerIsActive: false, isForeignMenuOnScreen: true) == .none)
        #expect(d.poll(now: ms(5000), isFading: false, ownerIsActive: false, isForeignMenuOnScreen: true) == .none)
        #expect(d.phase == .outsideClick(at: ms(0), grace: .milliseconds(300)))
        // The menu closed: toggle right away.
        #expect(d.poll(now: ms(5100), isFading: false, ownerIsActive: false) == .clickItem)
    }

    @Test func defersTheClickAfterEscapeToo() {
        var d = OutsideClickDismissal()
        click(&d, outside, at: 0)
        #expect(d.poll(now: ms(300), isFading: false, ownerIsActive: true) == .sendEscape)
        #expect(d.poll(now: ms(1000), isFading: false, ownerIsActive: true, isMouseButtonPressed: true) == .none)
        #expect(d.poll(now: ms(1100), isFading: false, ownerIsActive: true, isForeignMenuOnScreen: true) == .none)
        #expect(d.phase == .escapeSent(at: ms(300)))
        #expect(d.poll(now: ms(1200), isFading: false, ownerIsActive: true) == .clickItem)
    }

    @Test func givingUpIsNeverDeferred() {
        // Giving up posts nothing (the caller moves the icon back as usual), so there is nothing to protect.
        var d = OutsideClickDismissal()
        click(&d, outside, at: 0)
        #expect(d.poll(now: ms(300), isFading: false, ownerIsActive: false) == .clickItem)
        #expect(d.poll(now: ms(1300), isFading: false, ownerIsActive: false, isMouseButtonPressed: true,
                       isForeignMenuOnScreen: true) == .giveUp)
    }

    @Test func eachActionIsStillIssuedOnceWithDeferrals() {
        var d = OutsideClickDismissal()
        click(&d, outside, at: 0)
        let actions = stride(from: 0, through: 6000, by: 50).map { t in
            // Busy for a while in the middle of the escalation.
            let busy = (500..<2500).contains(t)
            return d.poll(now: ms(t), isFading: false, ownerIsActive: true, isMouseButtonPressed: busy)
        }
        #expect(actions.filter { $0 != .none } == [.sendEscape, .clickItem, .giveUp])
    }

    @Test func foreignMenusAreMenusOutsideThePresentation() {
        typealias W = ItemClicker.WindowInfo
        let popover = W(windowID: 10, layer: 25, ownerPID: 500)
        let ownMenu = W(windowID: 11, layer: 101, ownerPID: 500)
        let otherMenu = W(windowID: 12, layer: 101, ownerPID: 600)
        let otherWindow = W(windowID: 13, layer: 0, ownerPID: 600)
        // A menu that is part of the presentation (the item's own menu) doesn't count.
        #expect(!ItemClicker.containsForeignMenu([popover, ownMenu, otherWindow], presentation: [10, 11]))
        // Another app's menu does, and so does a menu the presentation opened later (the user is using it).
        #expect(ItemClicker.containsForeignMenu([popover, otherMenu], presentation: [10]))
        #expect(ItemClicker.containsForeignMenu([popover, ownMenu], presentation: [10]))
        #expect(!ItemClicker.containsForeignMenu([popover, otherWindow], presentation: [10]))
    }
}
