import Testing
import CoreGraphics
@testable import FrostCore

@Suite struct MenuBarItemTests {
    func item(title: String, bundle: String?) -> MenuBarItem {
        MenuBarItem(windowID: 1, frame: CGRect(x: 0, y: 0, width: 30, height: 24), isOnScreen: true,
                    windowTitle: title, bundleID: bundle, pid: 42, axDescription: nil)
    }

    @Test func identityCombinesBundleAndTitle() {
        let i = item(title: "Item-0", bundle: "com.example.app")
        #expect(i.identity == ItemIdentity(bundleID: "com.example.app", title: "Item-0"))
    }

    @Test func identityFallsBackToUnknownBundle() {
        #expect(item(title: "X", bundle: nil).identity.bundleID == "unknown")
    }

    @Test(arguments: ["Clock", "BentoBox-0", "BentoBox"])
    func controlCenterClockAndBentoAreImmovable(title: String) {
        #expect(item(title: title, bundle: "com.apple.controlcenter").isMovable == false)
    }

    @Test func otherControlCenterItemsAreMovable() {
        #expect(item(title: "WiFi", bundle: "com.apple.controlcenter").isMovable)
    }

    @Test func thirdPartyClockIsMovable() {
        #expect(item(title: "Clock", bundle: "com.example.clock").isMovable)
    }

    @Test func unresolvedClockIsTreatedAsImmovable() {
        // Be conservative while ownership is unresolved: better not to move the system clock
        #expect(item(title: "Clock", bundle: nil).isMovable == false)
        #expect(item(title: "Item-0", bundle: nil).isMovable)
    }

    @Test func sectionsAreOrderedLeftToRight() {
        #expect(MenuBarSection.leftToRight == [.alwaysHidden, .hidden, .visible])
    }
}
