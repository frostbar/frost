import Testing
import CoreGraphics
@testable import FrostCore

@Suite struct LandingDetectorTests {
    func f(_ x: CGFloat, _ w: CGFloat, y: CGFloat = 0) -> CGRect { CGRect(x: x, y: y, width: w, height: 24) }

    // Measured in the VM (collapsed): [H -3628 w5016][X -3767 w29 off screen]...[Icon 1388 w38][Clock 1426 w47][P 1473]
    // X (id 3) is moved right of the Frost icon (id 5): it lands at 1426 - 29 = 1397, while the icon and H slide left.
    let icon: CGWindowID = 5, item: CGWindowID = 3
    func snapshot(item x: CGFloat, y: CGFloat = 0, icon iconX: CGFloat = 1388) -> [CGWindowID: CGRect] {
        [4: f(iconX - 5016, 5016), item: f(x, 29, y: y), icon: f(iconX, 38), 6: f(1426, 47), 7: f(1473, 49)]
    }

    /// `#expect` can't call a mutating method.
    func observe(_ detector: inout LandingDetector, _ frames: [CGWindowID: CGRect]) -> Bool {
        detector.observe(frames)
    }

    @Test func landsOnceDockedInItsSlotForTwoSnapshotsWhileTheIconStillSlides() {
        var detector = LandingDetector(itemID: item, destination: .rightOf(icon))
        // Before the drag (off screen, left of H), then lifted: hanging at the cursor, below the row.
        #expect(!observe(&detector, snapshot(item: -3767)))
        #expect(!observe(&detector, snapshot(item: 1403, y: 12)))
        #expect(!observe(&detector, snapshot(item: 1403, y: 12)))
        // Dropped: one intermediate frame overlapping the clock, then its slot.
        #expect(!observe(&detector, snapshot(item: 1419)))
        #expect(!observe(&detector, snapshot(item: 1397, icon: 1380)))
        #expect(observe(&detector, snapshot(item: 1397, icon: 1371)))
    }

    @Test func aChangedFrameStartsOver() {
        var detector = LandingDetector(itemID: item, destination: .rightOf(icon))
        #expect(!observe(&detector, snapshot(item: 1397)))
        // The clock got wider (its title changed): everything left of it shifts, the item with it.
        var wider = snapshot(item: 1395)
        wider[6] = f(1424, 49)
        #expect(!observe(&detector, wider))
        #expect(observe(&detector, wider))
    }

    @Test func notLandedInTheWrongSlot() {
        var detector = LandingDetector(itemID: item, destination: .rightOf(icon))
        // Docked against the icon, i.e. left of it: the order is wrong.
        for _ in 0..<3 { #expect(!observe(&detector, snapshot(item: 1388 - 29, icon: 1388))) }
    }

    @Test func notLandedWithoutAWindowOnItsRight() {
        var detector = LandingDetector(itemID: item, destination: .rightOf(icon))
        let frames: [CGWindowID: CGRect] = [icon: f(1388, 38), item: f(1426, 29)]
        for _ in 0..<3 { #expect(!observe(&detector, frames)) }
    }

    @Test func dockedNeedsTheSameRowAndTouchingEdges() {
        #expect(LandingDetector.isDocked(item, frames: snapshot(item: 1397)))
        #expect(LandingDetector.isDocked(item, frames: snapshot(item: 1397.5)))
        #expect(!LandingDetector.isDocked(item, frames: snapshot(item: 1397, y: 12)))
        #expect(!LandingDetector.isDocked(item, frames: snapshot(item: 1390)))
        #expect(!LandingDetector.isDocked(item, frames: snapshot(item: 1419)))
        #expect(!LandingDetector.isDocked(99, frames: snapshot(item: 1397)))
    }
}

@MainActor @Suite struct ItemMoverLandingTests {
    func f(_ x: CGFloat, _ w: CGFloat, y: CGFloat = 0) -> CGRect { CGRect(x: x, y: y, width: w, height: 24) }

    final class Script {
        var snapshots: [[CGWindowID: CGRect]]
        var calls = 0
        init(_ snapshots: [[CGWindowID: CGRect]]) { self.snapshots = snapshots }
        func next() -> [CGWindowID: CGRect] {
            defer { calls += 1 }
            return snapshots[min(calls, snapshots.count - 1)]
        }
    }

    @Test func waitForLandingReturnsAsSoonAsTheItemHasLanded() async throws {
        let lifted: [CGWindowID: CGRect] = [3: f(1403, 29, y: 12), 5: f(1388, 38), 6: f(1426, 47)]
        let landed: [CGWindowID: CGRect] = [3: f(1397, 29), 5: f(1380, 38), 6: f(1426, 47)]
        var sliding = landed
        sliding[5] = f(1370, 38)
        let script = Script([lifted, landed, sliding, sliding])
        let result = try await ItemMover.waitForLanding(LandingDetector(itemID: 3, destination: .rightOf(5)),
                                                        interval: .milliseconds(1), timeout: .seconds(5),
                                                        snapshot: script.next)
        #expect(result)
        #expect(script.calls == 3)
    }

    @Test func waitForLandingTimesOutWhenTheMoveDidNotTakeEffect() async throws {
        let unmoved: [CGWindowID: CGRect] = [3: f(-3767, 29), 5: f(1388, 38), 6: f(1426, 47)]
        let result = try await ItemMover.waitForLanding(LandingDetector(itemID: 3, destination: .rightOf(5)),
                                                        interval: .milliseconds(1), timeout: .milliseconds(20),
                                                        snapshot: { unmoved })
        #expect(!result)
    }

    @Test func fallbackSettleKeepsTheRestOfTheTimeoutButCoolsDownBeforeARetry() {
        #expect(ItemMover.remainingSettleTimeout(.seconds(1), elapsed: .milliseconds(200)) == .milliseconds(800))
        #expect(ItemMover.remainingSettleTimeout(.seconds(1), elapsed: .milliseconds(700))
            == ItemMover.minimumFallbackSettle)
        #expect(ItemMover.remainingSettleTimeout(.seconds(1), elapsed: .seconds(2)) == ItemMover.minimumFallbackSettle)
    }
}

@Suite struct ForwardTraceTests {
    @Test func describesMarksInMillisecondsSinceTheStart() {
        let start = ContinuousClock.now
        var trace = ForwardTrace(start: start)
        trace.mark("transaction", at: start + .microseconds(10_400))
        trace.mark("click", at: start + .milliseconds(152))
        #expect(trace.description == "transaction 10, click 152")
        #expect(trace.marks.map(\.label) == ["transaction", "click"])
    }
}
