import Testing
import CoreGraphics
@testable import FrostCore

@Suite struct CaptureRetryPolicyTests {
    typealias Context = CaptureRetryPolicy.Context
    let display = CaptureRetryPolicy.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
    var context: Context { Context(itemOrder: [10, 11, 12, 13], displays: [display]) }

    @Test func everythingIsExpandableInitially() {
        var policy = CaptureRetryPolicy()
        #expect(policy.expandable([11, 12], in: context) == [11, 12])
    }

    @Test func itemsStillMissingAfterAnAttemptAreNotRetriedInTheSameContext() {
        var policy = CaptureRetryPolicy()
        policy.recordAttempt([11, 12], stillMissing: [12], in: context)
        #expect(policy.expandable([12], in: context) == [])
        // Another (newly missing) item still triggers an expand.
        #expect(policy.expandable([13, 12], in: context) == [13])
        // Repeated opens don't retry either.
        #expect(policy.expandable([12], in: context) == [])
    }

    @Test func capturedItemsAreNotBlocked() {
        var policy = CaptureRetryPolicy()
        policy.recordAttempt([11, 12], stillMissing: [], in: context)
        #expect(policy.blocked.isEmpty)
        #expect(policy.expandable([11], in: context) == [11])
    }

    @Test func reorderingUnblocks() {
        var policy = CaptureRetryPolicy()
        policy.recordAttempt([12], stillMissing: [12], in: context)
        let reordered = Context(itemOrder: [10, 12, 11, 13], displays: [display])
        #expect(policy.expandable([12], in: reordered) == [12])
        // Returning to the original context after the blocks were lifted doesn't restore the old blocks.
        #expect(policy.expandable([12], in: context) == [12])
    }

    @Test func itemSetChangeUnblocks() {
        var policy = CaptureRetryPolicy()
        policy.recordAttempt([12], stillMissing: [12], in: context)
        let added = Context(itemOrder: [9, 10, 11, 12, 13], displays: [display])
        #expect(policy.expandable([12], in: added) == [12])
        var removed = CaptureRetryPolicy()
        removed.recordAttempt([12], stillMissing: [12], in: context)
        #expect(removed.expandable([12], in: Context(itemOrder: [10, 12, 13], displays: [display])) == [12])
    }

    @Test func displayChangeUnblocks() {
        var policy = CaptureRetryPolicy()
        policy.recordAttempt([12], stillMissing: [12], in: context)
        var resized = display
        resized.frame.size.width = 1728
        #expect(policy.expandable([12], in: Context(itemOrder: context.itemOrder, displays: [resized])) == [12])

        var rescaled = CaptureRetryPolicy()
        rescaled.recordAttempt([12], stillMissing: [12], in: context)
        var lowDPI = display
        lowDPI.scale = 1
        #expect(rescaled.expandable([12], in: Context(itemOrder: context.itemOrder, displays: [lowDPI])) == [12])

        var added = CaptureRetryPolicy()
        added.recordAttempt([12], stillMissing: [12], in: context)
        let external = CaptureRetryPolicy.Display(id: 2, frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                                                  scale: 1)
        #expect(added.expandable([12], in: Context(itemOrder: context.itemOrder, displays: [display, external]))
            == [12])
    }

    @Test func recordingAgainInTheSameContextAccumulates() {
        var policy = CaptureRetryPolicy()
        policy.recordAttempt([11], stillMissing: [11], in: context)
        policy.recordAttempt([12], stillMissing: [12], in: context)
        #expect(policy.blocked == [11, 12])
    }

    @Test func recordingInANewContextReplacesTheOldBlocks() {
        var policy = CaptureRetryPolicy()
        policy.recordAttempt([11], stillMissing: [11], in: context)
        let other = Context(itemOrder: [10, 11, 13, 12], displays: [display])
        policy.recordAttempt([12], stillMissing: [12], in: other)
        #expect(policy.blocked == [12])
        #expect(policy.expandable([11, 12], in: other) == [11])
    }

    @Test func resetUnblocks() {
        var policy = CaptureRetryPolicy()
        policy.recordAttempt([12], stillMissing: [12], in: context)
        policy.reset()
        #expect(policy.expandable([12], in: context) == [12])
    }

    @Test func contextOrdersItemsLeftToRightIgnoringWidth() {
        func item(_ id: CGWindowID, x: CGFloat, width: CGFloat = 30) -> MenuBarItem {
            MenuBarItem(windowID: id, frame: CGRect(x: x, y: 0, width: width, height: 24), isOnScreen: x >= 0,
                        windowTitle: "", bundleID: nil, pid: nil, axDescription: nil)
        }
        let a = Context(items: [item(3, x: 100), item(1, x: -4000), item(2, x: 50)], displays: [display])
        #expect(a.itemOrder == [1, 2, 3])
        // Only a width change (e.g. the clock): the context is unchanged.
        let b = Context(items: [item(2, x: 50, width: 60), item(1, x: -4000), item(3, x: 100)], displays: [display])
        #expect(a == b)
    }
}
