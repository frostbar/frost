import Testing
import CoreGraphics
@testable import FrostCore

@Suite struct LiveRefreshPolicyTests {
    typealias Policy = LiveRefreshPolicy

    // MARK: Cadence

    @Test func firstCycleStartsImmediately() {
        #expect(Policy.delayBeforeNextCycle(sinceLastStart: nil, sinceLastEnd: nil) == .zero)
    }

    @Test func cadenceIsStartToStart() {
        // A cycle took 0.5 s: the next one starts 1 s after the previous start, i.e. 0.5 s after it ended.
        #expect(Policy.delayBeforeNextCycle(sinceLastStart: .milliseconds(500), sinceLastEnd: .zero)
                == .milliseconds(500))
        // A cycle took 0.25 s.
        #expect(Policy.delayBeforeNextCycle(sinceLastStart: .milliseconds(250), sinceLastEnd: .zero)
                == .milliseconds(750))
    }

    @Test func overrunningCycleKeepsTheMinimumGap() {
        // A cycle took 1.3 s: wait at least another 200 ms after it ended.
        #expect(Policy.delayBeforeNextCycle(sinceLastStart: .milliseconds(1300), sinceLastEnd: .zero)
                == .milliseconds(200))
        // A cycle took 0.9 s: the start-to-start constraint (100 ms) is less than the minimum gap (200 ms).
        #expect(Policy.delayBeforeNextCycle(sinceLastStart: .milliseconds(900), sinceLastEnd: .zero)
                == .milliseconds(200))
    }

    @Test func noWaitOnceBothConstraintsHavePassed() {
        #expect(Policy.delayBeforeNextCycle(sinceLastStart: .milliseconds(1500), sinceLastEnd: .milliseconds(900))
                == .zero)
    }

    @Test func forcedCycleOnlyRespectsTheGapAfterTheLastCycle() {
        // ⌥ toggle / refresh: not bound by period, but still separated from the cycle that just ended by minimumGap.
        #expect(Policy.delayBeforeNextCycle(sinceLastStart: nil, sinceLastEnd: .milliseconds(50))
                == .milliseconds(150))
    }

    @Test func firstCycleWaitsForThePanelToFinishAppearing() {
        // The freeze frame must capture the panel's final look (including its shadow reaching into the menu bar):
        // don't start before the appearance animation ends.
        #expect(Policy.delayBeforeNextCycle(sinceLastStart: nil, sinceLastEnd: nil, sincePresented: .zero)
                == Policy.appearanceDuration)
        #expect(Policy.delayBeforeNextCycle(sinceLastStart: nil, sinceLastEnd: nil, sincePresented: .milliseconds(150))
                == Policy.appearanceDuration - .milliseconds(150))
        #expect(Policy.delayBeforeNextCycle(sinceLastStart: nil, sinceLastEnd: nil, sincePresented: .seconds(2))
                == .zero)
        // The other constraints still combine (the largest wins).
        #expect(Policy.delayBeforeNextCycle(sinceLastStart: .milliseconds(100), sinceLastEnd: .zero,
                                            sincePresented: .milliseconds(100)) == .milliseconds(900))
        // The appearance animation is 0.18 s (`FrostBarController.present`), plus a small margin.
        #expect(Policy.appearanceDuration == .milliseconds(250))
    }

    @Test func constantsMatchTheRequestedCadence() {
        #expect(Policy.period == .seconds(1))
        #expect(Policy.minimumGap == .milliseconds(200))
    }

    // MARK: Pause rules

    @Test func runsWhenNothingIsInTheWay() {
        #expect(Policy.skipReason(.init()) == nil)
    }

    @Test(arguments: [
        (Policy.Conditions(isPanelOpen: false), Policy.SkipReason.panelClosed),
        (Policy.Conditions(hasPermissions: false), .permissionsMissing),
        (Policy.Conditions(isActivationInFlight: true), .activation),
        (Policy.Conditions(isMoveInFlight: true), .move),
        (Policy.Conditions(isEditing: true), .editing),
        (Policy.Conditions(isCollapsed: false), .notCollapsed),
        (Policy.Conditions(isMouseButtonPressed: true), .mouseDown),
        (Policy.Conditions(isMenuOnScreen: true), .menuOpen),
        (Policy.Conditions(isForwardedPresentationOnScreen: true), .presentationOpen),
        (Policy.Conditions(isPointerOverChangingMenuBar: true), .pointerInMenuBar),
        (Policy.Conditions(hasCapturableItems: false), .nothingToCapture),
    ])
    func eachConditionPausesTheLoop(conditions: Policy.Conditions, reason: Policy.SkipReason) {
        #expect(Policy.skipReason(conditions) == reason)
    }

    @Test func closedPanelWinsOverEverythingElse() {
        let all = Policy.Conditions(isPanelOpen: false, hasPermissions: false, isActivationInFlight: true,
                                    isMoveInFlight: true, isMouseButtonPressed: true, isMenuOnScreen: true,
                                    isForwardedPresentationOnScreen: true, isEditing: true, isCollapsed: false,
                                    isPointerOverChangingMenuBar: true, hasCapturableItems: false)
        #expect(Policy.skipReason(all) == .panelClosed)
    }

    @Test func activationAndMovesArePausesNotJustFailures() {
        // No expanding during click forwarding or move transactions (both are also serialized by
        // `ItemMover.transaction`).
        #expect(Policy.skipReason(.init(isActivationInFlight: true, isMoveInFlight: true)) == .activation)
    }

    @Test func abortsMidCycleOnCloseMouseDownOrPointerInMenuBar() {
        #expect(!Policy.shouldAbortCycle(isPanelOpen: true, isMouseButtonPressed: false,
                                         isPointerOverChangingMenuBar: false))
        #expect(Policy.shouldAbortCycle(isPanelOpen: false, isMouseButtonPressed: false,
                                        isPointerOverChangingMenuBar: false))
        #expect(Policy.shouldAbortCycle(isPanelOpen: true, isMouseButtonPressed: true,
                                        isPointerOverChangingMenuBar: false))
        #expect(Policy.shouldAbortCycle(isPanelOpen: true, isMouseButtonPressed: false,
                                        isPointerOverChangingMenuBar: true))
    }

    // MARK: Changing menu bar region

    // AppKit coordinates: main display 1728×1117, menu bar 30 pt tall (y 1087…1117);
    // the Frost icon is at x 1490…1520.
    let strip = CGRect(x: 0, y: 1087, width: 1728, height: 30)
    let icon = CGRect(x: 1490, y: 1087, width: 30, height: 30)

    @Test func onlyTheLeftOfTheFrostIconChanges() {
        #expect(Policy.changingRegion(of: strip, iconFrame: icon) == CGRect(x: 0, y: 1087, width: 1490, height: 30))
    }

    @Test func freezeFrameIsSnappedToDevicePixels() {
        // 2×: edges round to 0.5 pt, so the capture's pixel size matches the window's exactly (no scaling, no blur).
        let region = CGRect(x: 0, y: 1087, width: 1409.3, height: 30)
        #expect(Policy.pixelAligned(region, scale: 2) == CGRect(x: 0, y: 1087, width: 1409.5, height: 30))
        #expect(Policy.pixelAligned(CGRect(x: 1728.2, y: 1057.74, width: 99.6, height: 24), scale: 2)
                == CGRect(x: 1728, y: 1057.5, width: 100, height: 24))
        // 1×: rounds to whole points.
        #expect(Policy.pixelAligned(CGRect(x: 0.4, y: 0, width: 10.2, height: 24), scale: 1)
                == CGRect(x: 0, y: 0, width: 11, height: 24))
        // Already aligned: unchanged.
        #expect(Policy.pixelAligned(region.integral, scale: 2) == region.integral)
    }

    @Test func stripsWithoutTheIconAreCoveredEntirely() {
        let other = CGRect(x: 1728, y: 1057, width: 1920, height: 24)
        #expect(Policy.changingRegion(of: other, iconFrame: icon) == other)
        #expect(Policy.changingRegion(of: strip, iconFrame: nil) == strip)
    }

    @Test func pointerOverTheChangingPartPauses() {
        let strips = [strip]
        #expect(Policy.isPointerInChangingRegion(CGPoint(x: 800, y: 1100), strips: strips, iconFrame: icon))
        // On the snowflake (just clicked to open the panel) or to its right (clock): no pause.
        #expect(!Policy.isPointerInChangingRegion(CGPoint(x: 1500, y: 1100), strips: strips, iconFrame: icon))
        #expect(!Policy.isPointerInChangingRegion(CGPoint(x: 1650, y: 1110), strips: strips, iconFrame: icon))
        // Below the menu bar (in the panel).
        #expect(!Policy.isPointerInChangingRegion(CGPoint(x: 800, y: 1000), strips: strips, iconFrame: icon))
    }

    @Test func eachDisplayKeepsTheRightOfItsOwnFrostIconLive() {
        // The snowflake replica on the secondary display (to the right, 30 pt menu bar) is at x 3329: that strip is
        // covered only to its left, so the secondary display's clock also stays live.
        let other = CGRect(x: 1728, y: 1087, width: 1920, height: 30)
        let replica = CGRect(x: 3329, y: other.minY, width: 38, height: 30)
        #expect(Policy.changingRegion(of: other, iconFrames: [icon, replica])
                == CGRect(x: 1728, y: other.minY, width: 3329 - 1728, height: 30))
        #expect(Policy.changingRegion(of: strip, iconFrames: [icon, replica])
                == CGRect(x: 0, y: 1087, width: 1490, height: 30))
        #expect(Policy.isPointerInChangingRegion(CGPoint(x: 2000, y: other.midY), strips: [strip, other],
                                                 iconFrames: [icon, replica]))
        #expect(!Policy.isPointerInChangingRegion(CGPoint(x: 3400, y: other.midY), strips: [strip, other],
                                                  iconFrames: [icon, replica]))
        // Replica position unknown: the whole strip is covered (the pointer over its clock counts too).
        #expect(Policy.isPointerInChangingRegion(CGPoint(x: 3400, y: other.midY), strips: [strip, other],
                                                 iconFrames: [icon]))
    }
}

@Suite struct StripCropTests {
    let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    @Test func stripCoversAllItemsInDisplayLocalPoints() {
        let frames = [CGRect(x: 1115, y: 0, width: 49, height: 30), CGRect(x: 1328, y: 0, width: 110, height: 30)]
        #expect(StripCrop.stripRect(covering: frames, display: display)
                == CGRect(x: 1115, y: 0, width: 323, height: 30))
    }

    @Test func stripIsLocalToASecondaryDisplay() {
        let secondary = CGRect(x: 1728, y: -200, width: 1920, height: 1080)
        let frames = [CGRect(x: 2000.5, y: -200, width: 40, height: 24)]
        #expect(StripCrop.stripRect(covering: frames, display: secondary)
                == CGRect(x: 272, y: 0, width: 41, height: 24))
    }

    @Test func offscreenFramesAreIgnored() {
        #expect(StripCrop.stripRect(covering: [CGRect(x: -5000, y: 0, width: 40, height: 30)], display: display) == nil)
        let frames = [CGRect(x: -5000, y: 0, width: 40, height: 30), CGRect(x: 100, y: 0, width: 40, height: 30)]
        #expect(StripCrop.stripRect(covering: frames, display: display) == CGRect(x: 100, y: 0, width: 40, height: 30))
    }

    @Test func pixelRectMatchesPerWindowCaptureSize() {
        // Strip starts at x 1115, scale 2: FIWide (1328, 110 pt) → pixels (426, 0, 220, 60).
        let rect = StripCrop.pixelRect(of: CGRect(x: 1328, y: 0, width: 110, height: 30),
                                       stripOrigin: CGPoint(x: 1115, y: 0), scale: 2,
                                       imageSize: CGSize(width: 646, height: 60))
        #expect(rect == CGRect(x: 426, y: 0, width: 220, height: 60))
    }

    @Test func pixelRectOutsideTheImageIsRejected() {
        let size = CGSize(width: 646, height: 60)
        let origin = CGPoint(x: 1115, y: 0)
        #expect(StripCrop.pixelRect(of: CGRect(x: 1400, y: 0, width: 110, height: 30), stripOrigin: origin, scale: 2,
                                    imageSize: size) == nil)
        #expect(StripCrop.pixelRect(of: CGRect(x: 1100, y: 0, width: 40, height: 30), stripOrigin: origin, scale: 2,
                                    imageSize: size) == nil)
        #expect(StripCrop.pixelRect(of: CGRect(x: 1200, y: 0, width: 0, height: 30), stripOrigin: origin, scale: 2,
                                    imageSize: size) == nil)
    }
}

@Suite struct SettleDetectorTests {
    /// Feeds snapshots in order and returns the result of each.
    func feed(_ values: [Int], baseline: Int = 0, required: Int = 2) -> [Bool] {
        var detector = SettleDetector(baseline: baseline, requiredStablePolls: required)
        return values.map { detector.observe($0) }
    }

    @Test func settlesOnceChangedAndStableForTwoPolls() {
        // Not applied yet → applied (first seen) → identical twice in a row.
        #expect(feed([0, 5, 5]) == [false, false, true])
    }

    @Test func movingFramesResetTheCount() {
        #expect(feed([3, 4, 5, 5]) == [false, false, false, true])
    }

    @Test func returningToTheBaselineIsNotSettled() {
        #expect(feed([5, 0, 0, 0]) == [false, false, false, false])
    }

    @Test func requiredPollsAreConfigurable() {
        #expect(feed([1, 1, 1], required: 3) == [false, false, true])
    }
}

@Suite struct PixelCopyTests {
    func image(width: Int, height: Int, fill: CGColor) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(fill)
        ctx.fill(CGRect(x: 1, y: 1, width: width - 2, height: height - 2))
        return ctx.makeImage()!
    }

    @Test func identicalImagesHaveIdenticalBytes() {
        let a = PixelCopy(image(width: 8, height: 6, fill: CGColor(red: 1, green: 1, blue: 1, alpha: 1)))
        let b = PixelCopy(image(width: 8, height: 6, fill: CGColor(red: 1, green: 1, blue: 1, alpha: 1)))
        #expect(a != nil && a?.bytes == b?.bytes)
    }

    @Test func differentImagesDiffer() {
        let a = PixelCopy(image(width: 8, height: 6, fill: CGColor(red: 1, green: 1, blue: 1, alpha: 1)))
        let b = PixelCopy(image(width: 8, height: 6, fill: CGColor(red: 0, green: 0, blue: 0, alpha: 1)))
        #expect(a?.bytes != b?.bytes)
    }

    @Test func cropsBecomeStandaloneImagesWithTheirOwnPixels() throws {
        let strip = image(width: 40, height: 6, fill: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let crop = try #require(strip.cropping(to: CGRect(x: 10, y: 0, width: 8, height: 6)))
        let copy = try #require(PixelCopy(crop))
        #expect(copy.image.width == 8 && copy.image.height == 6)
        #expect(copy.bytes.count == 8 * 6 * 4)
        // The transparent border is preserved (the alpha channel is copied as is).
        #expect(GlyphPixels(copy.image)?.opaque == 8 * 4)
    }
}
