import Testing
import CoreGraphics
@testable import FrostCore

@Suite struct DragReleaseTests {
    func f(_ x: CGFloat, _ w: CGFloat = 32, y: CGFloat = 0) -> CGRect { CGRect(x: x, y: y, width: w, height: 30) }

    // Editing state measured in the VM: [A 1026][B 1058][T 1090][H 1147 w24][Icon 1374 w38][V 1412].
    // Item A (id 1) is dragged right of B, i.e. leftOf(T): T slides left by A's width while A is lifted.
    let before: [CGWindowID: CGRect] = [1: CGRect(x: 1026, y: 0, width: 32, height: 30),
                                        2: CGRect(x: 1058, y: 0, width: 32, height: 30),
                                        3: CGRect(x: 1090, y: 0, width: 60, height: 30),
                                        4: CGRect(x: 1374, y: 0, width: 38, height: 30)]

    /// `#expect` can't call a mutating method.
    func observe(_ release: inout DragRelease, _ frames: [CGWindowID: CGRect]) -> Bool { release.observe(frames) }

    func lifted(_ frames: [CGWindowID: CGRect], shift: CGFloat) -> [CGWindowID: CGRect] {
        var frames = frames
        frames[1] = f(1393, y: 15) // the lifted item sits at the cursor (the icon's center)
        for id in [2, 3] as [CGWindowID] { frames[id]?.origin.x -= shift }
        return frames
    }

    @Test func waitsForTheLiftBeforeReleasing() {
        var release = DragRelease(itemID: 1, destination: .rightOf(4), originalFrame: before[1]!,
                                  waitsForStillness: false)
        // A mouse-up before the lift is ignored by the system (the item doesn't move).
        for _ in 0..<5 { #expect(!observe(&release, before)) }
        #expect(!release.isLifted)
        let up = lifted(before, shift: 0)
        #expect(!observe(&release, up))
        #expect(release.isLifted)
        #expect(!observe(&release, up))
        #expect(observe(&release, up))
    }

    @Test func waitsUntilSlidingWindowsStopWhenTheTargetMaySlide() {
        var release = DragRelease(itemID: 1, destination: .leftOf(3), originalFrame: before[1]!,
                                  waitsForStillness: true)
        #expect(!observe(&release, before))
        // The gap closes over several snapshots; the target keeps moving.
        for shift in [4, 12, 20, 26, 30] as [CGFloat] { #expect(!observe(&release, lifted(before, shift: shift))) }
        let settled = lifted(before, shift: 32)
        #expect(!observe(&release, settled))
        #expect(!observe(&release, settled))
        #expect(observe(&release, settled))
        // Aimed at the target where it is now, not where it was before the drag.
        #expect(release.dropPoint(in: settled) == CGPoint(x: 1090 - 32 + 1, y: 15))
    }

    @Test func dropPointIsNilWithoutTheTarget() {
        let release = DragRelease(itemID: 1, destination: .leftOf(99), originalFrame: before[1]!,
                                  waitsForStillness: false)
        #expect(release.dropPoint(in: before) == nil)
    }

    @Test func targetsBetweenTheItemAndTheIconMaySlide() {
        let icon = f(1374, 38)
        func maySlide(item: CGFloat, _ destination: MoveDestination, target: CGFloat) -> Bool {
            DragRelease.targetMaySlide(itemFrame: f(item), destination: destination, targetFrame: f(target),
                                       iconID: 4, iconFrame: icon)
        }
        // Rightwards within Hidden / from Always Hidden into Hidden (the failing editor drops).
        #expect(maySlide(item: 1026, .leftOf(3), target: 1090))
        #expect(maySlide(item: 1026, .rightOf(2), target: 1058))
        // Leftwards within Visible, right of the icon.
        #expect(maySlide(item: 1494, .leftOf(5), target: 1445))
        // Beyond the icon or beyond the item: they don't slide.
        #expect(!maySlide(item: 1026, .leftOf(6), target: 1530))
        #expect(!maySlide(item: 1494, .leftOf(1), target: 975))
        #expect(!maySlide(item: 1090, .leftOf(1), target: 1026))
    }

    @Test func movingOutRightOfTheIconNeverWaits() {
        // The Frost Bar moves a hidden icon out to the right of the Frost icon: that gap stays under the point.
        let icon = f(1366, 38)
        #expect(!DragRelease.targetMaySlide(itemFrame: f(-3821), destination: .rightOf(4), targetFrame: icon,
                                            iconID: 4, iconFrame: icon))
        // Other destinations next to the icon might slide with it.
        #expect(DragRelease.targetMaySlide(itemFrame: f(-3821), destination: .leftOf(4), targetFrame: icon,
                                           iconID: 4, iconFrame: icon))
        #expect(DragRelease.targetMaySlide(itemFrame: f(1500), destination: .rightOf(4), targetFrame: icon,
                                           iconID: 4, iconFrame: icon))
    }
}
