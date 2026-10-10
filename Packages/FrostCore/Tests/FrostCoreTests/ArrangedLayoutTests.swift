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

    @Test func collapsedStaleFramesDoNotReorderTheRevealedSnapshot() {
        let layout = ArrangedLayout.layout(of: [item(3, x: 10), item(1, x: 200), item(2, x: 300)],
                                           own: [], order: [1, 2, 3], remembered: { _ in .hidden })
        #expect(layout[.hidden]?.map(\.windowID) == [1, 2, 3])
    }

    @Test func snapshotDropsVanishedItemsAndAddsNewIconsWithoutChangingKnownOrder() {
        let layout = ArrangedLayout.layout(of: [item(3, x: 10), item(1, x: 200), item(4, x: 50)],
                                           own: [], order: [1, 2, 3],
                                           remembered: { $0.windowID == 4 ? nil : .hidden })
        #expect(layout[.hidden]?.map(\.windowID) == [1, 3])
        #expect(layout[.visible]?.map(\.windowID) == [4])
    }
}

/// The overflow chevron is the bar's own control, not one of the user's icons (`SystemItemRules.isOverflowChevron`):
/// it appears and goes with how full the bar is, and inside a section it would be picked as the immovable anchor a
/// drop at the end of that section resolves against.
@Suite struct ArrangedLayoutChevronTests {
    private func menuBarAgent(_ id: CGWindowID, _ x: CGFloat, description: String? = nil) -> MenuBarItem {
        MenuBarItem(windowID: id, frame: CGRect(x: x, y: 0, width: 30, height: 24), isOnScreen: true, windowTitle: "",
                    bundleID: SystemItemRules.menuBarAgentBundleID, pid: 100, axDescription: description,
                    identityKey: "desc:Icon")
    }

    private func appItem(_ id: CGWindowID, _ x: CGFloat) -> MenuBarItem {
        MenuBarItem(windowID: id, frame: CGRect(x: x, y: 0, width: 30, height: 24), isOnScreen: true, windowTitle: "",
                    bundleID: "com.example.app", pid: 100, axDescription: "Icon", identityKey: "desc:Icon")
    }

    @Test func theChevronIsNotPartOfAnySection() {
        let chevron = menuBarAgent(9, 400, description: "Show Hidden Menu Bar Items")
        let layout = ArrangedLayout.layout(of: [chevron, appItem(1, 900)], own: [], remembered: { _ in nil })
        #expect(layout.values.flatMap { $0 }.map(\.windowID) == [1])
    }

    /// The clock and the Control Center button come from the same process and *are* part of the bar; only the item
    /// that describes itself is the chevron.
    @Test func theClockAndControlCenterStay() {
        let layout = ArrangedLayout.layout(of: [menuBarAgent(2, 1500), menuBarAgent(3, 1600)], own: [],
                                           remembered: { _ in nil })
        #expect(layout[.visible]?.map(\.windowID) == [2, 3])
    }
}
