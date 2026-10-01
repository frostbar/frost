import CoreGraphics
import Foundation
import Testing
@testable import FrostCore

@Suite struct ReplicaClickDetectorTests {
    // Real-hardware layout: built-in display active (real snowflake at 1395), external display on the right
    // (replica at 3313, 38 wide, 30 pt menu bar).
    let replicas: [CGDirectDisplayID: CGRect] = [4: CGRect(x: 3313, y: 0, width: 38, height: 30)]
    
    /// Reference wrapper: `#expect` can't call a value type's mutating methods.
    final class Harness {
        var detector = ReplicaClickDetector()
        let replicas: [CGDirectDisplayID: CGRect]
        init(replicas: [CGDirectDisplayID: CGRect]) { self.replicas = replicas }

        func down(at point: CGPoint = CGPoint(x: 3330, y: 15), time: TimeInterval = 100,
                  button: ReplicaClickDetector.Button = .left, control: Bool = false, option: Bool = false) -> Bool {
            detector.globalMouseDown(at: point, time: time, button: button, control: control, option: option,
                                     replicaIcons: replicas)
        }
        func mouseUp(button: ReplicaClickDetector.Button, time: TimeInterval) { detector.mouseUp(button: button, time: time) }
        func deliveredMouseDown(time: TimeInterval) { detector.deliveredMouseDown(time: time) }
        func actionReceived(eventTime: TimeInterval) -> Bool { detector.actionReceived(eventTime: eventTime) }
        func due(now: TimeInterval) -> ReplicaClickDetector.Click? { detector.due(now: now) }
        var hasPendingClick: Bool { detector.hasPendingClick }
    }

    func harness() -> Harness { Harness(replicas: replicas) }

    @Test func undeliveredClickOnReplicaIsSynthesizedAfterTheGrace() {
        let d = harness()
        #expect(d.down())
        d.mouseUp(button: .left, time: 100.04)
        #expect(d.due(now: 100.1) == nil)
        #expect(d.due(now: 100.04 + ReplicaClickDetector.grace - 0.01) == nil)
        let click = d.due(now: 100.04 + ReplicaClickDetector.grace)
        #expect(click == .init(displayID: 4, button: .left, control: false, option: false))
        #expect(click?.isContextClick == false)
        // Synthesized only once.
        #expect(d.due(now: 101) == nil)
        #expect(!d.hasPendingClick)
    }

    @Test func noSynthesisBeforeTheMouseIsReleased() {
        let d = harness()
        #expect(d.down())
        #expect(d.due(now: 100.5) == nil)
        #expect(d.hasPendingClick)
        // Held past the limit (drag, long press): give up, and don't synthesize even after the up.
        #expect(d.due(now: 100 + ReplicaClickDetector.maxHold) == nil)
        #expect(!d.hasPendingClick)
        d.mouseUp(button: .left, time: 102.5)
        #expect(d.due(now: 104) == nil)
    }

    @Test func redeliveredMouseDownCancelsTheSynthesis() {
        // Measured in the VM: the global monitor sees the down / up first; about 35 ms later the local monitor sees
        // a down with the same timestamp on the icon window, and the button then fires its action.
        let d = harness()
        #expect(d.down(time: 830.407503))
        d.mouseUp(button: .left, time: 830.448247)
        d.deliveredMouseDown(time: 830.407503)
        #expect(!d.hasPendingClick)
        #expect(d.actionReceived(eventTime: 830.448247))
        #expect(d.due(now: 832) == nil)
    }

    @Test func aDifferentDeliveredMouseDownDoesNotCancel() {
        let d = harness()
        #expect(d.down(time: 100))
        d.mouseUp(button: .left, time: 100.05)
        d.deliveredMouseDown(time: 99.2)
        #expect(d.hasPendingClick)
        #expect(d.due(now: 100.4) != nil)
    }

    @Test func buttonActionCancelsThePendingClick() {
        let d = harness()
        #expect(d.down())
        d.mouseUp(button: .left, time: 100.05)
        #expect(d.actionReceived(eventTime: 100.05))
        #expect(d.due(now: 101) == nil)
    }

    @Test func lateActionForASynthesizedClickIsIgnored() {
        let d = harness()
        #expect(d.down())
        d.mouseUp(button: .left, time: 100.05)
        #expect(d.due(now: 100.4) != nil)
        // The system belatedly delivers the same click to the button: don't toggle again.
        #expect(!d.actionReceived(eventTime: 100.05))
        // A later, new click from the user is handled as usual.
        #expect(d.actionReceived(eventTime: 101.2))
    }

    @Test func clicksElsewhereAreIgnoredAndClearAStalePendingClick() {
        let d = harness()
        #expect(!d.down(at: CGPoint(x: 3200, y: 15)))
        #expect(!d.down(at: CGPoint(x: 1410, y: 15)))
        #expect(!d.down(at: CGPoint(x: 3330, y: 600)))
        d.mouseUp(button: .left, time: 100.1)
        #expect(d.due(now: 101) == nil)
        // After the pending click the user clicked elsewhere (no up recorded): the later click wins.
        #expect(d.down())
        #expect(!d.down(at: CGPoint(x: 500, y: 500), time: 100.5))
        #expect(!d.hasPendingClick)
    }

    @Test func frameEdgesGetASmallSlop() {
        let d = harness()
        #expect(d.down(at: CGPoint(x: 3312.5, y: 15)))
        #expect(!d.down(at: CGPoint(x: 3311, y: 15)))
        #expect(d.down(at: CGPoint(x: 3351.5, y: 30.5)))
    }

    @Test func contextAndOptionClicksKeepTheirModifiers() {
        let d = harness()
        #expect(d.down(button: .right))
        // An up from a different button doesn't count.
        d.mouseUp(button: .left, time: 100.05)
        #expect(d.due(now: 101) == nil)
        d.mouseUp(button: .right, time: 100.06)
        let right = d.due(now: 101)
        #expect(right?.button == .right)
        #expect(right?.isContextClick == true)

        #expect(d.down(time: 200, control: true))
        d.mouseUp(button: .left, time: 200.05)
        #expect(d.due(now: 201)?.isContextClick == true)

        #expect(d.down(time: 300, option: true))
        d.mouseUp(button: .left, time: 300.05)
        #expect(d.due(now: 301) == .init(displayID: 4, button: .left, control: false, option: true))
    }

    @Test func picksTheReplicaOfTheClickedDisplay() {
        let three: [CGDirectDisplayID: CGRect] = [
            2: CGRect(x: -1500, y: 0, width: 38, height: 30),
            7: CGRect(x: 3313, y: 0, width: 38, height: 30),
        ]
        let d3 = Harness(replicas: three)
        #expect(d3.down(at: CGPoint(x: -1480, y: 10), time: 1))
        d3.mouseUp(button: .left, time: 1.05)
        #expect(d3.due(now: 2)?.displayID == 2)
    }
}
