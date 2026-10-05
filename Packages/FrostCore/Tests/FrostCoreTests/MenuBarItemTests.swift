import Testing
import CoreGraphics
@testable import FrostCore

@Suite struct MenuBarItemTests {
    func item(title: String = "", bundle: String?, identifier: String? = nil, key: String? = "desc:Item",
              systemSlot: Bool = false) -> MenuBarItem {
        MenuBarItem(windowID: 1, frame: CGRect(x: 0, y: 0, width: 30, height: 24), isOnScreen: true,
                    windowTitle: title, bundleID: bundle, pid: 42, axDescription: nil, axIdentifier: identifier,
                    identityKey: bundle == nil ? nil : key, occupiesSystemSlot: systemSlot)
    }

    @Test func identityCombinesBundleAndAXKey() {
        let i = item(title: "Item-0", bundle: "com.example.app", key: "desc:Weather")
        #expect(i.identity == ItemIdentity(bundleID: "com.example.app", key: "desc:Weather"))
    }

    @Test func identityDoesNotNeedATitle() {
        #expect(item(title: "", bundle: "com.example.app").identity != nil)
    }

    @Test func identityIsNilWhileUnresolved() {
        #expect(item(title: "X", bundle: nil).identity == nil)
        #expect(item(bundle: "com.example.app", key: nil).identity == nil)
    }

    @Test func legacyIdentitiesAreRecognized() {
        #expect(IdentityMigration.legacy(bundleID: "a", title: "T").isLegacy)
        #expect(!ItemIdentity(bundleID: "a", key: "desc:T").isLegacy)
    }

    @Test func withFrameKeepsEveryOtherAttribute() {
        let original = MenuBarItem(windowID: 7, frame: .zero, isOnScreen: false, windowTitle: "t", bundleID: "b",
                                   pid: 3, axDescription: "d", axTitle: "x", axIdentifier: "i", identityKey: "k",
                                   occupiesSystemSlot: true)
        let moved = original.with(frame: CGRect(x: 5, y: 0, width: 9, height: 9), isOnScreen: true)
        #expect(moved.axTitle == "x" && moved.axIdentifier == "i" && moved.identityKey == "k")
        #expect(moved.occupiesSystemSlot && moved.isOnScreen && moved.frame.minX == 5)
    }

    // MARK: Immovable items

    @Test(arguments: ["Clock", "BentoBox-0", "BentoBox"])
    func controlCenterClockAndBentoAreImmovableByTitle(title: String) {
        #expect(item(title: title, bundle: "com.apple.controlcenter").isMovable == false)
    }

    @Test(arguments: [SystemItemRules.clockIdentifier, SystemItemRules.controlCenterIdentifier])
    func clockAndControlCenterAreImmovableByAXIdentifierWithoutTitles(identifier: String) {
        #expect(item(bundle: "com.apple.controlcenter", identifier: identifier).isMovable == false)
    }

    @Test func otherControlCenterModulesAreMovableWithoutTitles() {
        #expect(item(bundle: "com.apple.controlcenter", identifier: "com.apple.menuextra.wifi").isMovable)
        // Even in a trailing slot: the identifier is stronger evidence than the position.
        #expect(item(bundle: "com.apple.controlcenter", identifier: "com.apple.menuextra.wifi",
                     systemSlot: true).isMovable)
    }

    @Test func otherControlCenterItemsAreMovable() {
        #expect(item(title: "WiFi", bundle: "com.apple.controlcenter").isMovable)
    }

    @Test func thirdPartyClockIsMovable() {
        #expect(item(title: "Clock", bundle: "com.example.clock").isMovable)
        #expect(item(bundle: "com.example.clock", identifier: SystemItemRules.clockIdentifier).isMovable)
        #expect(item(bundle: "com.example.clock", systemSlot: true).isMovable)
    }

    @Test func unresolvedClockIsTreatedAsImmovable() {
        // Be conservative while ownership is unresolved: better not to move the system clock
        #expect(item(title: "Clock", bundle: nil).isMovable == false)
        #expect(item(title: "Item-0", bundle: nil).isMovable)
    }

    @Test func withoutIdentifierOrTitleTheTrailingSlotsDecide() {
        // No Screen Recording and the owner not resolved yet: the two trailing windows are the clock and Control
        // Center.
        #expect(item(bundle: nil, systemSlot: true).isMovable == false)
        #expect(item(bundle: nil, systemSlot: false).isMovable)
        #expect(item(bundle: "com.apple.controlcenter", identifier: nil, systemSlot: true).isMovable == false)
        #expect(item(bundle: "com.apple.controlcenter", identifier: nil, systemSlot: false).isMovable)
    }

    @Test func trailingSlotsAreTheTwoRightmostOnScreenWindows() {
        func window(_ id: CGWindowID, x: CGFloat, width: CGFloat = 30, onScreen: Bool = true) -> RawStatusWindow {
            RawStatusWindow(windowID: id, frame: CGRect(x: x, y: 0, width: width, height: 24), title: "",
                            isOnScreen: onScreen)
        }
        let windows = [window(1, x: 1000), window(2, x: 1500, width: 26), window(3, x: 1530, width: 150),
                       window(4, x: -5000, width: 5016, onScreen: false), window(5, x: 1400)]
        #expect(SystemItemRules.trailingSlots(windows) == [2, 3])
        #expect(SystemItemRules.trailingSlots(windows, excluding: [3]) == [2, 5])
        #expect(SystemItemRules.trailingSlots([]) == [])
    }

    @Test func sectionsAreOrderedLeftToRight() {
        #expect(MenuBarSection.leftToRight == [.alwaysHidden, .hidden, .visible])
    }
}
