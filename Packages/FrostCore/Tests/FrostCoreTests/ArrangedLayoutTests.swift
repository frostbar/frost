import CoreGraphics
import Testing
@testable import FrostCore

/// The macOS 27 sections (`ArrangedLayout`): what the user arranged, never what geometry suggests.
@Suite struct ArrangedLayoutTests {
    private func item(_ id: CGWindowID, x: CGFloat, bundle: String = "com.example.app",
                      key: String = "desc:Icon") -> MenuBarItem {
        MenuBarItem(windowID: id, frame: CGRect(x: x, y: 0, width: 30, height: 24), isOnScreen: true,
                    windowTitle: "", bundleID: bundle, pid: 100, axDescription: "Icon", identityKey: key)
    }

    /// An icon Frost was never told about is visible. Guessing that it is hidden would be a claim Frost cannot
    /// support, and it is the failure mode that made arranged icons show up in the wrong band.
    @Test func unknownIconsAreVisible() {
        let layout = ArrangedLayout.layout(of: [item(1, x: 100), item(2, x: 200)], own: [], remembered: { _ in nil })
        #expect(layout[.visible]?.map(\.windowID) == [1, 2])
        #expect(layout[.hidden]?.isEmpty == true)
        #expect(layout[.alwaysHidden]?.isEmpty == true)
    }

    @Test func rememberedSectionsAreHonoured() {
        let remembered: [CGWindowID: MenuBarSection] = [1: .hidden, 3: .alwaysHidden]
        let layout = ArrangedLayout.layout(of: [item(1, x: 100), item(2, x: 200), item(3, x: 300)], own: [],
                                           remembered: { remembered[$0.windowID] })
        #expect(layout[.visible]?.map(\.windowID) == [2])
        #expect(layout[.hidden]?.map(\.windowID) == [1])
        #expect(layout[.alwaysHidden]?.map(\.windowID) == [3])
    }

    /// Frost's own items are not part of any section, whatever the memory says about them.
    @Test func ownItemsAreExcluded() {
        let layout = ArrangedLayout.layout(of: [item(1, x: 100), item(99, x: 900)], own: [99],
                                           remembered: { $0.windowID == 99 ? .hidden : nil })
        #expect(layout.values.flatMap { $0 }.map(\.windowID) == [1])
    }

    /// Bar order is left to right, also for an item whose frame is stale: the sections are the arrangement, the
    /// order still comes from the frames the bar reports.
    @Test func eachSectionIsInBarOrder() {
        let layout = ArrangedLayout.layout(of: [item(3, x: 300), item(1, x: 100), item(2, x: 200)], own: [],
                                           remembered: { _ in .hidden })
        #expect(layout[.hidden]?.map(\.windowID) == [1, 2, 3])
    }
}
