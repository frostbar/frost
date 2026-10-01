import Testing
import CoreGraphics
@testable import FrostCore

@Suite struct DropResolverTests {
    func item(_ id: CGWindowID, movable: Bool = true) -> MenuBarItem {
        MenuBarItem(windowID: id, frame: .zero, isOnScreen: true, windowTitle: movable ? "t\(id)" : "Clock",
                    bundleID: movable ? "b\(id)" : "com.apple.controlcenter", pid: 1, axDescription: nil)
    }
    let controls = FrostControlWindows(icon: 100, hiddenSeparator: 101, alwaysHiddenSeparator: 102)

    var layout: MenuBarLayout {
        [.alwaysHidden: [item(1)], .hidden: [item(2), item(3)], .visible: [item(4), item(9, movable: false)]]
    }

    @Test func dropBeforeExistingItemGoesLeftOfIt() {
        let d = DropResolver.destination(dragging: item(1), to: .hidden, index: 1, layout: layout, controls: controls)
        #expect(d == .leftOf(3))
    }

    @Test func dropAtEndOfHiddenGoesLeftOfHiddenSeparator() {
        let d = DropResolver.destination(dragging: item(1), to: .hidden, index: 2, layout: layout, controls: controls)
        #expect(d == .leftOf(101))
    }

    @Test func dropAtEndOfAlwaysHiddenGoesLeftOfAHSeparator() {
        let d = DropResolver.destination(dragging: item(2), to: .alwaysHidden, index: 1, layout: layout, controls: controls)
        #expect(d == .leftOf(102))
    }

    @Test func dropAtStartOfVisibleGoesLeftOfFirstVisible() {
        let d = DropResolver.destination(dragging: item(2), to: .visible, index: 0, layout: layout, controls: controls)
        #expect(d == .leftOf(4))
    }

    @Test func dropAfterImmovablesIsClampedBeforeFirstImmovable() {
        let d = DropResolver.destination(dragging: item(2), to: .visible, index: 5, layout: layout, controls: controls)
        #expect(d == .leftOf(9))
    }

    @Test func dropIntoEmptyVisibleGoesRightOfIcon() {
        var l = layout; l[.visible] = []
        let d = DropResolver.destination(dragging: item(2), to: .visible, index: 0, layout: l, controls: controls)
        #expect(d == .rightOf(100))
    }

    @Test func indexIsInterpretedAfterRemovingDraggedItem() {
        // Drag 2 to the end within hidden (index counts in the list with 2 removed, i.e. [3])
        let d = DropResolver.destination(dragging: item(2), to: .hidden, index: 1, layout: layout, controls: controls)
        #expect(d == .leftOf(101))
    }

    @Test func droppingImmovableReturnsNil() {
        let d = DropResolver.destination(dragging: item(9, movable: false), to: .hidden, index: 0, layout: layout, controls: controls)
        #expect(d == nil)
    }

    @Test func droppingInPlaceReturnsNil() {
        // 2 is already at position 0 in hidden; dropping it at position 0 in hidden → no move needed
        let d = DropResolver.destination(dragging: item(2), to: .hidden, index: 0, layout: layout, controls: controls)
        #expect(d == nil)
    }
}
