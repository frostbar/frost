import Testing
import CoreGraphics
@testable import FrostCore

@Suite struct RestorePlanTests {
    let controls = FrostControlWindows(icon: 100, hiddenSeparator: 101, alwaysHiddenSeparator: 102)

    func item(_ id: CGWindowID) -> MenuBarItem {
        MenuBarItem(windowID: id, frame: CGRect(x: CGFloat(id) * 30, y: 0, width: 30, height: 39), isOnScreen: false,
                    windowTitle: "t\(id)", bundleID: "b\(id)", pid: 1, axDescription: nil)
    }

    func layout(alwaysHidden: [CGWindowID] = [], hidden: [CGWindowID] = [], visible: [CGWindowID] = []) -> MenuBarLayout {
        [.alwaysHidden: alwaysHidden.map(item), .hidden: hidden.map(item), .visible: visible.map(item)]
    }

    @Test func prefersRightNeighbourThenLeftNeighbourThenBoundary() throws {
        let plan = try #require(RestorePlan.make(for: 2, in: layout(hidden: [1, 2, 3]), controls: controls))
        #expect(plan.section == .hidden)
        #expect(plan.candidates == [.leftOf(3), .rightOf(1), .leftOf(101)])
        #expect(plan.boundary == .leftOf(101))
    }

    @Test func rightmostItemUsesLeftNeighbour() throws {
        let plan = try #require(RestorePlan.make(for: 3, in: layout(hidden: [1, 2, 3]), controls: controls))
        #expect(plan.candidates == [.rightOf(2), .leftOf(101)])
    }

    @Test func onlyItemInSectionUsesBoundary() throws {
        let plan = try #require(RestorePlan.make(for: 1, in: layout(hidden: [1]), controls: controls))
        #expect(plan.candidates == [.leftOf(101)])
    }

    @Test func alwaysHiddenBoundaryIsAlwaysHiddenSeparator() throws {
        let plan = try #require(RestorePlan.make(for: 5, in: layout(alwaysHidden: [5], hidden: [1]), controls: controls))
        #expect(plan.section == .alwaysHidden)
        #expect(plan.candidates == [.leftOf(102)])
    }

    @Test func neighboursNeverCrossSections() throws {
        // 5 is the rightmost item in the always-hidden section: 1, immediately to its right, is in the hidden
        // section and must not be used as an anchor.
        let plan = try #require(RestorePlan.make(for: 5, in: layout(alwaysHidden: [4, 5], hidden: [1]),
                                                 controls: controls))
        #expect(plan.candidates == [.rightOf(4), .leftOf(102)])
    }

    @Test func visibleOrUnknownItemsNeedNoPlan() {
        #expect(RestorePlan.make(for: 7, in: layout(hidden: [1], visible: [7]), controls: controls) == nil)
        #expect(RestorePlan.make(for: 9, in: layout(hidden: [1]), controls: controls) == nil)
    }

    @Test func destinationUsesFirstAnchorStillInSection() throws {
        let plan = try #require(RestorePlan.make(for: 2, in: layout(hidden: [1, 2, 3]), controls: controls))
        // After moving out: 2 is in the visible section, 1 and 3 are still hidden.
        #expect(plan.destination(in: layout(hidden: [1, 3], visible: [2])) == .leftOf(3))
    }

    @Test func destinationFallsBackWhenAnchorVanished() throws {
        let plan = try #require(RestorePlan.make(for: 2, in: layout(hidden: [1, 2, 3]), controls: controls))
        // 3's app has quit.
        #expect(plan.destination(in: layout(hidden: [1], visible: [2])) == .rightOf(1))
        // Both 1 and 3 are gone.
        #expect(plan.destination(in: layout(hidden: [], visible: [2])) == .leftOf(101))
    }

    @Test func destinationSkipsAnchorMovedToAnotherSection() throws {
        let plan = try #require(RestorePlan.make(for: 2, in: layout(hidden: [1, 2, 3]), controls: controls))
        // 3 was moved to the visible section in the meantime: anchoring next to it would put 2 there too.
        #expect(plan.destination(in: layout(hidden: [1], visible: [2, 3])) == .rightOf(1))
    }

    @Test func destinationIsBoundaryWhenLayoutUnavailable() throws {
        let plan = try #require(RestorePlan.make(for: 2, in: layout(hidden: [1, 2, 3]), controls: controls))
        #expect(plan.destination(in: [:]) == .leftOf(101))
    }
}
