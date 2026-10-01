import Testing
import CoreGraphics
@testable import FrostCore

@Suite struct SectionAssignerTests {
    func item(_ id: CGWindowID, x: CGFloat, w: CGFloat = 30) -> MenuBarItem {
        MenuBarItem(windowID: id, frame: CGRect(x: x, y: 0, width: w, height: 24), isOnScreen: true,
                    windowTitle: "t\(id)", bundleID: "b\(id)", pid: 1, axDescription: nil)
    }
    let controls = FrostControlWindows(icon: 100, hiddenSeparator: 101, alwaysHiddenSeparator: 102)

    @Test func assignsByPositionRelativeToSeparators() {
        // Left → right: [1][AH][2][H][Icon][3]
        let items = [item(1, x: 0), item(102, x: 30, w: 10), item(2, x: 40), item(101, x: 70, w: 10),
                     item(100, x: 80), item(3, x: 110)]
        let layout = SectionAssigner.layout(of: items, controls: controls)
        #expect(layout[.alwaysHidden]?.map(\.windowID) == [1])
        #expect(layout[.hidden]?.map(\.windowID) == [2])
        #expect(layout[.visible]?.map(\.windowID) == [3])
    }

    @Test func worksWhenHiddenSeparatorIsExpandedOffscreen() {
        // When collapsed the H separator has length=10000, pushing the items left of it to negative coordinates
        let items = [item(1, x: -10_100), item(102, x: -10_060, w: 10), item(2, x: -10_040),
                     item(101, x: -10_000, w: 10_000), item(100, x: 0), item(3, x: 30)]
        let layout = SectionAssigner.layout(of: items, controls: controls)
        #expect(layout[.hidden]?.map(\.windowID) == [2])
        #expect(layout[.visible]?.map(\.windowID) == [3])
    }

    @Test func excludesControlItemsFromSections() {
        let items = [item(102, x: 0, w: 10), item(101, x: 10, w: 10), item(100, x: 20)]
        let layout = SectionAssigner.layout(of: items, controls: controls)
        #expect(MenuBarSection.allCases.allSatisfy { layout[$0, default: []].isEmpty })
    }

    @Test func returnsEmptyLayoutWhenControlsMissing() {
        let layout = SectionAssigner.layout(of: [item(1, x: 0)], controls: controls)
        #expect(layout.isEmpty)
    }
}
