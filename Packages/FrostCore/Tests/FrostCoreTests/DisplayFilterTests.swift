import Testing
import CoreGraphics
@testable import FrostCore

@Suite struct DisplayFilterTests {
    let main = CGRect(x: 0, y: 0, width: 1800, height: 1169)

    func ax(_ x: CGFloat, width: CGFloat = 30) -> AXItemInfo {
        AXItemInfo(bundleID: "b", pid: 1, frame: CGRect(x: x, y: 7.5, width: width, height: 24), description: nil)
    }

    func display(_ frame: CGRect, height: CGFloat = 39) -> MenuBarDisplay {
        MenuBarDisplay(id: 1, frame: frame, menuBarHeight: height)
    }

    @Test func axItemsKeepTheWholeMenuBarRowIncludingPushedOutItems() {
        // Pushed-out items (measured collapsed: X = −3487) also have a negative x in AX and must be kept to resolve ownership.
        let r = DisplayFilter.axItems([ax(1500), ax(-3488), ax(-8533)], onMenuBarOf: display(main))
        #expect(r.map(\.frame.minX) == [1500, -3488, -8533])
        // With a wide secondary display on the left, the real pushed-out items fall within its horizontal range:
        // keep them too (AX only describes real windows).
        let wideLeft = [ax(-1000), ax(-3488)]
        #expect(DisplayFilter.axItems(wideLeft, onMenuBarOf: display(main)).count == 2)
    }

    @Test func axItemsDropOtherMenuBarRows() {
        // Stacked vertically: with the active menu bar on the lower display (y = 1169), the AX items read are on its
        // row; stale results on the main display's row are dropped.
        let below = display(CGRect(x: 0, y: 1169, width: 1920, height: 1080), height: 30)
        let lower = AXItemInfo(bundleID: "b", pid: 1, frame: CGRect(x: 1500, y: 1169 + 3, width: 30, height: 24),
                               description: nil)
        #expect(DisplayFilter.axItems([ax(1500), lower], onMenuBarOf: below) == [lower])
        #expect(DisplayFilter.axItems([ax(1500), lower], onMenuBarOf: display(main)).map(\.frame.minY) == [7.5])
        // Auto-hiding menu bar (height 0): use the 60 pt row height upper bound.
        #expect(DisplayFilter.axItems([ax(1500)], onMenuBarOf: display(main, height: 0)).count == 1)
    }
}
