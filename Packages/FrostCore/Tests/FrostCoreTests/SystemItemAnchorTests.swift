import CoreGraphics
import Testing
@testable import FrostCore

/// Where the snowflake belongs (`SystemItemAnchor`): immediately left of the *trailing* system items.
@Suite struct SystemItemAnchorTests {
    private let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    private func item(_ id: CGWindowID, _ x: CGFloat, bundle: String? = "com.example.app",
                      description: String? = "Icon", identifier: String? = nil) -> MenuBarItem {
        MenuBarItem(windowID: id, frame: CGRect(x: x, y: 3, width: 30, height: 24), isOnScreen: true,
                    windowTitle: "", bundleID: bundle, pid: 100, axDescription: description,
                    axIdentifier: identifier, identityKey: "desc:Icon")
    }

    private func menuBarAgent(_ id: CGWindowID, _ x: CGFloat, description: String? = nil) -> MenuBarItem {
        item(id, x, bundle: SystemItemRules.menuBarAgentBundleID, description: description)
    }

    /// The ordinary case: the trailing clock and Control Center button, with the user's icons to their left.
    @Test func theTrailingSystemItemsAreTheAnchor() {
        let anchor = SystemItemAnchor.trailingAnchor(
            among: [item(1, 100), menuBarAgent(2, 1500), menuBarAgent(3, 1600)], own: [], displayBounds: display)
        #expect(anchor?.windowID == 2)
    }

    /// The bug this rule exists for: with everything hidden the overflow chevron is the leftmost immovable item, and
    /// anchoring on it would put the snowflake behind the chevron at the far left.
    @Test func theOverflowChevronIsNeverTheAnchor() {
        let chevron = menuBarAgent(9, 400, description: "Show Hidden Menu Bar Items")
        let anchor = SystemItemAnchor.trailingAnchor(
            among: [chevron, menuBarAgent(2, 1500), menuBarAgent(3, 1600)], own: [], displayBounds: display)
        #expect(anchor?.windowID == 2)

        // …also when the chevron is the only other thing in the trailing area.
        let chevronOnly = SystemItemAnchor.trailingAnchor(
            among: [chevron, menuBarAgent(3, 1600)], own: [], displayBounds: display)
        #expect(chevronOnly?.windowID == 3)
    }

    /// Frost's own items sit inside the trailing area and are not anchors.
    @Test func ownItemsAreSkipped() {
        let anchor = SystemItemAnchor.trailingAnchor(
            among: [item(1, 100), menuBarAgent(2, 1500), item(50, 1520), menuBarAgent(3, 1600)], own: [50],
            displayBounds: display)
        #expect(anchor?.windowID == 2)
    }

    /// A third-party icon at the right end stops the walk: the system items are the trailing run, nothing beyond it.
    @Test func aMovableItemEndsTheTrailingRun() {
        let anchor = SystemItemAnchor.trailingAnchor(
            among: [menuBarAgent(2, 100), item(1, 1500), menuBarAgent(3, 1600)], own: [], displayBounds: display)
        #expect(anchor?.windowID == 3)
    }

    /// Frames are global coordinates: a display placed left of the primary one gives its items a negative x, and
    /// those are still valid anchors — what matters is that the item is on the managed display.
    @Test func itemsOnADisplayToTheLeftAreUsable() {
        let leftDisplay = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let anchor = SystemItemAnchor.trailingAnchor(
            among: [item(1, -900), menuBarAgent(2, -400), menuBarAgent(3, -300)], own: [],
            displayBounds: leftDisplay)
        #expect(anchor?.windowID == 2)
    }

    /// An item outside the managed display is not an anchor for it.
    @Test func itemsOffTheManagedDisplayAreIgnored() {
        let anchor = SystemItemAnchor.trailingAnchor(
            among: [menuBarAgent(2, -500), menuBarAgent(3, 1600)], own: [], displayBounds: display)
        #expect(anchor?.windowID == 3)
    }
}
