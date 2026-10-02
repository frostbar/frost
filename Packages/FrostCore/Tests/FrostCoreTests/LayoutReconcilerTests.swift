import Testing
import CoreGraphics
@testable import FrostCore

@Suite struct LayoutReconcilerTests {
    func item(_ id: CGWindowID, onScreen: Bool = true) -> MenuBarItem {
        MenuBarItem(windowID: id, frame: .zero, isOnScreen: onScreen, windowTitle: "t\(id)",
                    bundleID: "b\(id)", pid: 1, axDescription: nil)
    }

    func ids(_ layout: MenuBarLayout) -> [MenuBarSection: [CGWindowID]] {
        layout.mapValues { $0.map(\.windowID) }
    }

    // MARK: - reconcile

    @Test func onScreenItemsKeepTheirLiveSection() {
        let previous: MenuBarLayout = [.alwaysHidden: [], .hidden: [item(1)], .visible: [item(2)]]
        let live: MenuBarLayout = [.alwaysHidden: [], .hidden: [item(2)], .visible: [item(1)]]
        let result = LayoutReconciler.reconcile(live: live, previous: previous)
        #expect(ids(result) == [.alwaysHidden: [], .hidden: [2], .visible: [1]])
    }

    @Test func offscreenItemThatChangedSectionStaysInPreviousSection() {
        // While editing, the system placed 3 (covered by the notch) left of AH: SectionAssigner misclassifies it as always hidden.
        let previous: MenuBarLayout = [.alwaysHidden: [item(1)], .hidden: [item(2), item(3), item(4)], .visible: []]
        let live: MenuBarLayout = [.alwaysHidden: [item(1), item(3, onScreen: false)],
                                   .hidden: [item(2), item(4)], .visible: []]
        let result = LayoutReconciler.reconcile(live: live, previous: previous)
        #expect(ids(result) == [.alwaysHidden: [1], .hidden: [2, 3, 4], .visible: []])
        #expect(result[.hidden]?[1].isOnScreen == false)  // uses the live data
    }

    @Test func overriddenItemWithoutPresentPredecessorGoesFirst() {
        let previous: MenuBarLayout = [.alwaysHidden: [], .hidden: [item(3), item(2)], .visible: []]
        let live: MenuBarLayout = [.alwaysHidden: [item(3, onScreen: false)], .hidden: [item(2)], .visible: []]
        let result = LayoutReconciler.reconcile(live: live, previous: previous)
        #expect(ids(result) == [.alwaysHidden: [], .hidden: [3, 2], .visible: []])
    }

    @Test func consecutiveOverriddenItemsKeepPreviousOrder() {
        let previous: MenuBarLayout = [.alwaysHidden: [], .hidden: [item(1), item(2), item(3), item(4)], .visible: []]
        let live: MenuBarLayout = [.alwaysHidden: [item(3, onScreen: false), item(2, onScreen: false)],
                                   .hidden: [item(1), item(4)], .visible: []]
        let result = LayoutReconciler.reconcile(live: live, previous: previous)
        #expect(ids(result) == [.alwaysHidden: [], .hidden: [1, 2, 3, 4], .visible: []])
    }

    @Test func offscreenItemInSameSectionKeepsPreviousOrder() {
        // Real hardware: the relative order of items under the notch within one section gets shuffled too.
        let previous: MenuBarLayout = [.alwaysHidden: [], .hidden: [item(1), item(2), item(3)], .visible: []]
        let live: MenuBarLayout = [.alwaysHidden: [], .hidden: [item(2), item(1, onScreen: false), item(3)], .visible: []]
        let result = LayoutReconciler.reconcile(live: live, previous: previous)
        #expect(ids(result) == [.alwaysHidden: [], .hidden: [1, 2, 3], .visible: []])
    }

    @Test func onScreenItemsKeepLiveOrderWithinSection() {
        let previous: MenuBarLayout = [.alwaysHidden: [], .hidden: [item(1), item(2)], .visible: []]
        let live: MenuBarLayout = [.alwaysHidden: [], .hidden: [item(2), item(1)], .visible: []]
        let result = LayoutReconciler.reconcile(live: live, previous: previous)
        #expect(ids(result) == [.alwaysHidden: [], .hidden: [2, 1], .visible: []])
    }

    @Test func fullyOffscreenLayoutEqualsPrevious() {
        // Temporarily collapsed during a move: the hidden sections are all pushed off screen; the display stays the same.
        let previous: MenuBarLayout = [.alwaysHidden: [item(5)], .hidden: [item(1), item(2)], .visible: [item(3)]]
        let live: MenuBarLayout = [.alwaysHidden: [item(2, onScreen: false), item(5, onScreen: false)],
                                   .hidden: [item(1, onScreen: false)], .visible: [item(3)]]
        #expect(ids(LayoutReconciler.reconcile(live: live, previous: previous)) == ids(previous))
    }

    @Test func newOffscreenItemUsesLiveSection() {
        let previous: MenuBarLayout = [.alwaysHidden: [], .hidden: [item(1)], .visible: []]
        let live: MenuBarLayout = [.alwaysHidden: [item(5, onScreen: false)], .hidden: [item(1)], .visible: []]
        let result = LayoutReconciler.reconcile(live: live, previous: previous)
        #expect(ids(result) == [.alwaysHidden: [5], .hidden: [1], .visible: []])
    }

    @Test func removedItemsDisappear() {
        let previous: MenuBarLayout = [.alwaysHidden: [], .hidden: [item(1), item(2)], .visible: []]
        let live: MenuBarLayout = [.alwaysHidden: [], .hidden: [item(1)], .visible: []]
        #expect(ids(LayoutReconciler.reconcile(live: live, previous: previous))
            == [.alwaysHidden: [], .hidden: [1], .visible: []])
    }

    @Test func emptyLiveLayoutStaysEmpty() {
        let previous: MenuBarLayout = [.alwaysHidden: [], .hidden: [item(1)], .visible: []]
        #expect(LayoutReconciler.reconcile(live: [:], previous: previous).isEmpty)
    }

    @Test func emptyPreviousReturnsLive() {
        let live: MenuBarLayout = [.alwaysHidden: [item(3, onScreen: false)], .hidden: [item(1)], .visible: []]
        #expect(ids(LayoutReconciler.reconcile(live: live, previous: [:])) == ids(live))
    }

    // MARK: - moving

    let base: MenuBarLayout = [.alwaysHidden: [], .hidden: [], .visible: []]

    @Test func movingWithinSectionUsesIndexAfterRemoval() {
        // [A,B,C] drop A before C → index 1 after removing A → [B,A,C]
        var layout = base
        layout[.hidden] = [item(1), item(2), item(3)]
        let result = LayoutReconciler.moving(1, to: .hidden, at: 1, in: layout)
        #expect(result[.hidden]?.map(\.windowID) == [2, 1, 3])
    }

    @Test func movingAcrossSections() {
        var layout = base
        layout[.hidden] = [item(1), item(2)]
        layout[.visible] = [item(3)]
        let result = LayoutReconciler.moving(2, to: .visible, at: 0, in: layout)
        #expect(ids(result) == [.alwaysHidden: [], .hidden: [1], .visible: [2, 3]])
    }

    @Test func movingClampsIndex() {
        var layout = base
        layout[.hidden] = [item(1)]
        let result = LayoutReconciler.moving(1, to: .alwaysHidden, at: 7, in: layout)
        #expect(ids(result) == [.alwaysHidden: [1], .hidden: [], .visible: []])
    }

    @Test func movingUnknownItemIsNoOp() {
        var layout = base
        layout[.hidden] = [item(1)]
        #expect(ids(LayoutReconciler.moving(9, to: .visible, at: 0, in: layout)) == ids(layout))
    }

    @Test func keepsPreviousSectionsWhenASeparatorIsOffScreen() {
        // Collapsed snapshot: 1 is always hidden, 2 and 3 hidden. While editing on a notched display the AH separator
        // is squeezed under the notch, so the on-screen item 1 is classified Hidden.
        let previous: MenuBarLayout = [.alwaysHidden: [item(1)], .hidden: [item(2), item(3)],
                                       .visible: []]
        let live: MenuBarLayout = [.alwaysHidden: [], .hidden: [item(1), item(2), item(3)],
                                   .visible: [], ]
        let untrusted = LayoutReconciler.reconcile(live: live, previous: previous, separatorsOnScreen: false)
        #expect(untrusted[.alwaysHidden]?.map(\.windowID) == [1])
        #expect(untrusted[.hidden]?.map(\.windowID) == [2, 3])
        // With both separators on screen, on-screen items use their live sections.
        let trusted = LayoutReconciler.reconcile(live: live, previous: previous)
        #expect(trusted[.alwaysHidden]?.map(\.windowID) == [])
        #expect(trusted[.hidden]?.map(\.windowID) == [1, 2, 3])
    }

    @Test func newItemsUseLiveSectionsEvenWhenSeparatorsAreOffScreen() {
        let previous: MenuBarLayout = [.alwaysHidden: [], .hidden: [item(2)], .visible: []]
        let live: MenuBarLayout = [.alwaysHidden: [], .hidden: [item(2), item(9)], .visible: []]
        let result = LayoutReconciler.reconcile(live: live, previous: previous, separatorsOnScreen: false)
        #expect(result[.hidden]?.map(\.windowID) == [2, 9])
    }
}
