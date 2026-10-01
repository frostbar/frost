import Testing
import CoreGraphics
@testable import FrostCore

@MainActor @Suite struct ItemMoverTests {
    func f(_ x: CGFloat, _ w: CGFloat = 29) -> CGRect { CGRect(x: x, y: 0, width: w, height: 39) }

    // Measured expandedAll: [Y 1468][AH 1497 w16][X 1513][H 1542 w16][Icon 1558][V 1587]
    var frames: [CGWindowID: CGRect] {
        [1: f(1468), 2: f(1497, 16), 3: f(1513), 4: f(1542, 16), 5: f(1558), 6: f(1587)]
    }

    @Test func satisfiedWhenImmediatelyLeftOfTarget() {
        #expect(ItemMover.isSatisfied(3, .leftOf(4), frames: frames))
        #expect(!ItemMover.isSatisfied(3, .leftOf(5), frames: frames))
        #expect(!ItemMover.isSatisfied(6, .leftOf(1), frames: frames))
    }

    @Test func satisfiedWhenImmediatelyRightOfTarget() {
        #expect(ItemMover.isSatisfied(6, .rightOf(5), frames: frames))
        #expect(!ItemMover.isSatisfied(6, .rightOf(4), frames: frames))
        #expect(!ItemMover.isSatisfied(1, .rightOf(6), frames: frames))
    }

    @Test func notSatisfiedWhenItemMissing() {
        #expect(!ItemMover.isSatisfied(99, .leftOf(4), frames: frames))
    }

    @Test func orderIgnoresDictionaryOrderAndHandlesOffscreenItems() {
        // collapsed: items pushed off screen are at negative x.
        let collapsed: [CGWindowID: CGRect] = [6: f(1587), 1: f(-8532), 4: f(-3458, 5016), 3: f(-3487),
                                               2: f(-8503, 5016), 5: f(1558)]
        #expect(ItemMover.isSatisfied(3, .leftOf(4), frames: collapsed))
        #expect(ItemMover.isSatisfied(3, .rightOf(2), frames: collapsed))
    }

    func item(_ id: CGWindowID, x: CGFloat, onScreen: Bool) -> MenuBarItem {
        MenuBarItem(windowID: id, frame: f(x), isOnScreen: onScreen, windowTitle: "t\(id)", bundleID: "b\(id)",
                    pid: 1, axDescription: nil)
    }
    let display = CGRect(x: 0, y: 0, width: 1800, height: 1169)

    @Test func notchObscuredItemsAreNotVerifiable() {
        // While editing, items under the notch are tucked left of AH; x doesn't reflect the real order.
        let onScreen = item(5, x: 1558, onScreen: true)
        #expect(!ItemMover.isVerifiable(item(3, x: 907, onScreen: false), target: onScreen, displayBounds: display))
        #expect(!ItemMover.isVerifiable(onScreen, target: item(4, x: 945, onScreen: false), displayBounds: display))
        #expect(ItemMover.isVerifiable(item(3, x: 1513, onScreen: true), target: onScreen, displayBounds: display))
    }

    @Test func pushedOutItemsAreVerifiable() {
        // While collapsed, items pushed off to the left of the main display are in a trustworthy order.
        #expect(ItemMover.isVerifiable(item(3, x: -3500, onScreen: false), target: item(4, x: -3471, onScreen: false),
                                       displayBounds: display))
    }

    @Test func dropPointsUseTargetEdgesWithoutClamping() {
        #expect(ItemMover.dropPoint(for: .leftOf(4), targetFrame: f(1542, 16)) == CGPoint(x: 1543, y: 19.5))
        #expect(ItemMover.dropPoint(for: .rightOf(5), targetFrame: f(1558)) == CGPoint(x: 1586, y: 19.5))
        // Off-screen target: raw coordinates (measured X → right of Y, end point (−8504, 19.5)).
        #expect(ItemMover.dropPoint(for: .rightOf(1), targetFrame: f(-8532)) == CGPoint(x: -8504, y: 19.5))
    }

    // MARK: - Frost control order (AH < H < Icon)

    let controls = FrostControlWindows(icon: 5, hiddenSeparator: 4, alwaysHiddenSeparator: 2)

    func raw(_ id: CGWindowID, x: CGFloat, w: CGFloat = 29, onScreen: Bool = true) -> RawStatusWindow {
        RawStatusWindow(windowID: id, frame: f(x, w), title: "", isOnScreen: onScreen)
    }

    @Test func controlsInOrderInExpandedAndCollapsedStates() {
        // Measured expandedAll: [Y 1468][AH 1497 w16][X 1513][H 1542 w16][Icon 1558][V 1587]
        let expanded = [raw(1, x: 1468), raw(2, x: 1497, w: 16), raw(3, x: 1513), raw(4, x: 1542, w: 16),
                        raw(5, x: 1558), raw(6, x: 1587)]
        #expect(ItemMover.controlsInOrder(controls, windows: expanded, displayBounds: display))
        // Measured collapsed: separators pushed off screen (5016 pt, onscreen=false, but the right end reaches on screen).
        let collapsed = [raw(2, x: -8503, w: 5016, onScreen: false), raw(4, x: -3458, w: 5016, onScreen: false),
                         raw(5, x: 1558), raw(6, x: 1587)]
        #expect(ItemMover.controlsInOrder(controls, windows: collapsed, displayBounds: display))
    }

    @Test func detectsIconDraggedLeftOfSeparators() {
        // When routing degrades to position-based, the Frost icon is what gets dragged: it landed left of H (pushed off
        // screen while collapsed).
        let iconLeftOfH = [raw(2, x: -8503, w: 5016, onScreen: false), raw(5, x: -3487, onScreen: false),
                           raw(4, x: -3458, w: 5016, onScreen: false)]
        #expect(!ItemMover.controlsInOrder(controls, windows: iconLeftOfH, displayBounds: display))
        let iconLeftOfAH = [raw(5, x: 1400), raw(2, x: 1497, w: 16), raw(4, x: 1542, w: 16)]
        #expect(!ItemMover.controlsInOrder(controls, windows: iconLeftOfAH, displayBounds: display))
        let separatorsSwapped = [raw(4, x: 1497, w: 16), raw(2, x: 1542, w: 16), raw(5, x: 1558)]
        #expect(!ItemMover.controlsInOrder(controls, windows: separatorsSwapped, displayBounds: display))
    }

    @Test func controlOrderCheckSkipsMissingOrNotchObscuredControls() {
        // Missing control: no evidence, don't report.
        #expect(ItemMover.controlsInOrder(controls, windows: [raw(5, x: 1558)], displayBounds: display))
        // While editing, AH is under the notch (onscreen=false, x within the screen bounds): x is untrustworthy, so
        // don't report based on it.
        let obscured = [raw(2, x: 1600, w: 24, onScreen: false), raw(4, x: 1534, w: 24), raw(5, x: 1558)]
        #expect(ItemMover.controlsInOrder(controls, windows: obscured, displayBounds: display))
    }

    /// Returns the scripted snapshots in order, then keeps returning the last one.
    final class Script {
        var snapshots: [[CGWindowID: CGRect]]
        var calls = 0
        init(_ snapshots: [[CGWindowID: CGRect]]) { self.snapshots = snapshots }
        func next() -> [CGWindowID: CGRect] {
            defer { calls += 1 }
            return snapshots[min(calls, snapshots.count - 1)]
        }
    }

    func settle(_ script: Script, timeout: Duration = .seconds(5),
                satisfied: @escaping ([CGWindowID: CGRect]) -> Bool) async throws -> ItemMover.SettleResult {
        try await ItemMover.waitForSettle(initialDelay: .zero, interval: .milliseconds(1), timeout: timeout,
                                          snapshot: script.next, satisfied: satisfied)
    }

    @Test func settlesOnceOrderIsCorrectAndFramesStopChanging() async throws {
        // X moves from left of H to right of Icon; the other items shift during the animation, then stop.
        let before = frames
        var moving = frames; moving[3] = f(1587); moving[6] = f(1600)
        var moving2 = moving; moving2[6] = f(1610)
        var final = moving; final[6] = f(1616)
        let script = Script([before, moving, moving2, final, final, final, final])
        let r = try await settle(script) { ItemMover.isSatisfied(3, .rightOf(5), frames: $0) }
        #expect(r == .init(satisfied: true, settled: true))
        #expect(script.calls == 6) // after final first appears, it must repeat twice more
    }

    @Test func timesOutWhenMoveNeverTakesEffect() async throws {
        let script = Script([frames])
        let r = try await settle(script, timeout: .milliseconds(30)) { ItemMover.isSatisfied(3, .rightOf(5), frames: $0) }
        #expect(r == .init(satisfied: false, settled: false))
    }

    @Test func reportsSatisfiedButUnsettledWhenAnimationOutlastsTimeout() async throws {
        var n: CGFloat = 0
        let satisfiedButMoving: () -> [CGWindowID: CGRect] = {
            n += 1
            return [3: CGRect(x: 2000 + n, y: 0, width: 29, height: 39), 5: CGRect(x: 1558, y: 0, width: 29, height: 39)]
        }
        let r = try await ItemMover.waitForSettle(initialDelay: .zero, interval: .milliseconds(1),
                                                  timeout: .milliseconds(30), snapshot: satisfiedButMoving,
                                                  satisfied: { ItemMover.isSatisfied(3, .rightOf(5), frames: $0) })
        #expect(r == .init(satisfied: true, settled: false))
    }

    @Test func cancellationThrows() async {
        let task = Task {
            try await ItemMover.waitForSettle(initialDelay: .seconds(10), interval: .milliseconds(1),
                                              timeout: .seconds(20), snapshot: { [:] }, satisfied: { _ in false })
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
