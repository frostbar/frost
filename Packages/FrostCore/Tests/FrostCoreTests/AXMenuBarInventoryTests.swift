import CoreGraphics
import Testing
@testable import FrostCore

/// The macOS 27 inventory (`AXMenuBarInventory`): the synthesized identities and the item list built from
/// Accessibility, where there is no window list to build it from.
@Suite struct AXMenuBarInventoryTests {
    private let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    private func axItem(_ key: String, x: CGFloat, pid: pid_t = 100, bundle: String = "com.example.app",
                        description: String = "Icon", title: String? = nil) -> AXItemInfo {
        AXItemInfo(bundleID: bundle, pid: pid, frame: CGRect(x: x, y: 3, width: 30, height: 24),
                   description: description, title: title, identifier: nil, identityKey: key)
    }

    /// The synthesized ID is what stands in for a window ID: the same identity must always map to the same one, or
    /// every scan would look like a different menu bar to the sections, the memory and the Frost Bar.
    @Test func identitiesMapToStableWindowIDs() {
        let first = AXMenuBarInventory.windowID(bundleID: "com.example.app", identityKey: "desc:Icon", pid: 100)
        let again = AXMenuBarInventory.windowID(bundleID: "com.example.app", identityKey: "desc:Icon", pid: 100)
        #expect(first == again)
        #expect(first != 0)
        #expect(first != AXMenuBarInventory.windowID(bundleID: "com.example.app", identityKey: "desc:Other", pid: 100))
        #expect(first != AXMenuBarInventory.windowID(bundleID: "com.example.other", identityKey: "desc:Icon", pid: 100))
        // Two processes of the same app can have identical identity keys, and they are different icons.
        #expect(first != AXMenuBarInventory.windowID(bundleID: "com.example.app", identityKey: "desc:Icon", pid: 101))
    }

    /// Frost's own items live in the same namespace without colliding with anything.
    @Test func ownItemsGetTheirOwnStableIDs() {
        let icon = AXMenuBarInventory.ownWindowID(autosaveName: "FrostIcon")
        #expect(icon == AXMenuBarInventory.ownWindowID(autosaveName: "FrostIcon"))
        #expect(icon != AXMenuBarInventory.ownWindowID(autosaveName: "Frost27.HiddenDivider"))
        #expect(icon != AXMenuBarInventory.windowID(bundleID: "dev.frost.Frost", identityKey: "desc:Frost", pid: 1))
    }

    /// One item per window, in bar order, with ownership carried over — including Frost's own items, which the AX
    /// read never returns (it skips this process) and which the app layer passes in.
    @Test func scanBuildsTheListInBarOrder() {
        let scan = AXMenuBarInventory.scan(
            axItems: [axItem("desc:B", x: 200), axItem("desc:A", x: 100)],
            own: [.init(autosaveName: "FrostIcon", frame: CGRect(x: 900, y: 0, width: 24, height: 30))],
            displayBounds: display)
        #expect(scan.windows.map(\.frame.minX) == [100, 200, 900])
        #expect(scan.windows.count == scan.ownership.count)
        for window in scan.windows { #expect(scan.ownership[window.windowID] != nil) }
    }

    /// A text item often has no AX title; the description is then the only name it has, and it is what the identity
    /// and the fallback label are built from.
    @Test func titleFallsBackToTheDescription() {
        let scan = AXMenuBarInventory.scan(axItems: [axItem("desc:Percent", x: 100, description: "Percent",
                                                            title: "42%")],
                                           own: [], displayBounds: display)
        #expect(scan.windows.first?.title == "42%")

        let withoutTitle = AXMenuBarInventory.scan(axItems: [axItem("desc:Percent", x: 100, description: "Percent")],
                                                   own: [], displayBounds: display)
        #expect(withoutTitle.windows.first?.title == "Percent")
    }

    /// An item pushed off the left of the display is reported as off screen (geometry only: whether it is *drawn*
    /// cannot be read on 27, which is why nothing derives visibility from this).
    @Test func itemsOutsideTheDisplayAreNotOnScreen() {
        let scan = AXMenuBarInventory.scan(axItems: [axItem("desc:A", x: -200), axItem("desc:B", x: 100)],
                                           own: [], displayBounds: display)
        #expect(scan.windows.first { $0.frame.minX == -200 }?.isOnScreen == false)
        #expect(scan.windows.first { $0.frame.minX == 100 }?.isOnScreen == true)
    }
}
