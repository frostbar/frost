import Testing
@testable import FrostCore

/// Which menu bar items the system owns (`SystemItemRules`): they are never moved, hidden or dragged.
@Suite struct SystemItemRulesTests {
    /// macOS 26: Control Center's clock and Control Center button, recognized by their AX identifiers.
    @Test func controlCentersOwnItemsAreFixed() {
        #expect(SystemItemRules.isFixed(bundleID: SystemItemRules.controlCenterBundleID,
                                        axIdentifier: SystemItemRules.clockIdentifier, windowTitle: "",
                                        occupiesSystemSlot: false))
        #expect(SystemItemRules.isFixed(bundleID: SystemItemRules.controlCenterBundleID,
                                        axIdentifier: SystemItemRules.controlCenterIdentifier, windowTitle: "",
                                        occupiesSystemSlot: false))
        // A Control Center module (not the clock or the button) is movable: it has its own identifier.
        #expect(!SystemItemRules.isFixed(bundleID: SystemItemRules.controlCenterBundleID,
                                         axIdentifier: "com.apple.menuextra.battery", windowTitle: "",
                                         occupiesSystemSlot: false))
    }

    /// macOS 27: the bar's own process owns the clock, the Control Center button **and** the overflow chevron, none
    /// of which describe themselves the way Control Center's items do on 26. Matching on the owner is what tells them
    /// apart — without it the chevron was treated as one of the user's icons and offered as a drop target, and a drop
    /// then failed because the chevron disappears as soon as the bar stops overflowing.
    @Test func everythingMenuBarAgentOwnsIsFixed() {
        #expect(SystemItemRules.isFixed(bundleID: SystemItemRules.menuBarAgentBundleID, axIdentifier: nil,
                                        windowTitle: "", occupiesSystemSlot: false))
        #expect(SystemItemRules.isFixed(bundleID: SystemItemRules.menuBarAgentBundleID, axIdentifier: nil,
                                        windowTitle: "Show Hidden Menu Bar Items", occupiesSystemSlot: false))
        #expect(SystemItemRules.isFixed(bundleID: SystemItemRules.menuBarAgentBundleID,
                                        axIdentifier: "com.apple.menuextra.clock", windowTitle: "",
                                        occupiesSystemSlot: true))
    }

    /// A third-party item is movable, also when it looks like a system one (its own clock, its own "BentoBox…").
    @Test func thirdPartyItemsAreMovable() {
        #expect(!SystemItemRules.isFixed(bundleID: "com.example.app", axIdentifier: nil, windowTitle: "Clock",
                                         occupiesSystemSlot: false))
        #expect(!SystemItemRules.isFixed(bundleID: "com.example.app", axIdentifier: nil,
                                         windowTitle: "BentoBox-0", occupiesSystemSlot: true))
    }
}
