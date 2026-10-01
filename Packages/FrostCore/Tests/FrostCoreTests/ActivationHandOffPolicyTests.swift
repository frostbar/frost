import Testing
import CoreGraphics
import Foundation
@testable import FrostCore

@Suite struct ActivationHandOffPolicyTests {
    let frost: pid_t = 100
    let app: pid_t = 500

    func decide(pid: pid_t?, bundleID: String? = "dev.frost.FakeItems", activatable: Bool = true,
                frostIsActive: Bool = false, frostWindows: Bool = false) -> ActivationHandOffPolicy.Decision {
        ActivationHandOffPolicy.decide(ownerPID: pid, bundleID: bundleID, ownPID: frost, targetActivatable: activatable,
                                       frostIsActive: frostIsActive, frostHasVisibleWindows: frostWindows)
    }

    @Test func handsOffToKnownThirdPartyApps() {
        #expect(decide(pid: app) == .handOff)
        // Bundle ID unresolved but pid known: hand-off still works (NSRunningApplication is looked up by pid).
        #expect(decide(pid: app, bundleID: nil) == .handOff)
    }

    @Test func skipsUnknownOwnersAndFrostItself() {
        #expect(decide(pid: nil) == .skip(.unknownOwner))
        #expect(decide(pid: frost) == .skip(.ownProcess))
    }

    @Test func skipsAppleSystemItems() {
        // Control Center modules, Spotlight, etc. use the HID click path and their presentations don't depend on
        // activation: keep the original behaviour.
        for id in ["com.apple.controlcenter", "com.apple.Spotlight", "com.apple.TextInputMenuAgent"] {
            #expect(decide(pid: app, bundleID: id) == .skip(.systemItem), "\(id)")
        }
        #expect(decide(pid: app, bundleID: "com.applecorp.Tool") == .handOff)
    }

    @Test func skipsTargetsThatCannotActivate() {
        #expect(decide(pid: app, activatable: false) == .skip(.targetNotActivatable))
    }

    @Test func doesNotRaiseFrostWindowsByActivatingFrost() {
        // Frost isn't frontmost and the settings window is open: activating Frost would bring it to the front.
        #expect(decide(pid: app, frostWindows: true) == .skip(.wouldRaiseFrostWindows))
        // Frost is already frontmost: no visible side effect.
        #expect(decide(pid: app, frostIsActive: true, frostWindows: true) == .handOff)
        #expect(decide(pid: app, frostIsActive: true) == .handOff)
    }

    @Test func frostCountsAsActiveOnlyWhenItIsTheFrontmostApp() {
        // Measured in the VM: while Frost Bar (a non-activating panel) is key, `NSApp.isActive` is true but the
        // frontmost app is still TextEdit. Treating that as "Frost already frontmost" skips activation and the
        // hand-off falls through: look only at the frontmost app.
        #expect(ActivationHandOffPolicy.isFrostActive(frontmostPID: frost, ownPID: frost))
        #expect(!ActivationHandOffPolicy.isFrostActive(frontmostPID: 300, ownPID: frost))
        #expect(!ActivationHandOffPolicy.isFrostActive(frontmostPID: nil, ownPID: frost))
    }

    func handBack(active: Bool, wasActive: Bool = false, previous: pid_t? = 300,
                  running: Bool = true, userChoseOtherApp: Bool = false) -> ActivationHandOffPolicy.HandBack {
        ActivationHandOffPolicy.handBack(frostIsActive: active, frostWasActive: wasActive, previousPID: previous,
                                         previousIsRunning: running, ownPID: frost,
                                         userChoseOtherApp: userChoseOtherApp)
    }

    @Test func handsActivationBackOnlyWhileFrostStillHoldsIt() {
        // Menu / item with no action: the target app didn't take activation → hand it back to the previous app.
        #expect(handBack(active: true) == .activatePrevious(300))
        // Popover: the target app is already active (or the user clicked another app) → do nothing.
        #expect(handBack(active: false) == .none)
        // Frost was already frontmost before the hand-off: leave things as they are.
        #expect(handBack(active: true, wasActive: true) == .none)
    }

    @Test func deactivatesWhenThePreviousAppIsGoneOrUnknown() {
        #expect(handBack(active: true, previous: nil) == .deactivate)
        #expect(handBack(active: true, running: false) == .deactivate)
        #expect(handBack(active: true, previous: frost) == .deactivate)
    }

    @Test func returnsToFrostWhenItWasFrontmostBeforeTheHandOff() {
        // Popover opened via Frost Bar while the settings window was open (Frost frontmost): activation goes to the
        // target app; after the popover closes the system gives frontmost to another regular app (Frost, being
        // LSUIElement, isn't a candidate) → return to Frost.
        #expect(handBack(active: false, wasActive: true) == .reactivateFrost)
        // The user clicked another app's window / the Dock / the desktop in the meantime: respect that choice.
        #expect(handBack(active: false, wasActive: true, userChoseOtherApp: true) == .none)
        // Frost is still frontmost (menus aren't handed off): do nothing.
        #expect(handBack(active: true, wasActive: true) == .none)
        // Frost wasn't frontmost before the hand-off: "return to Frost" doesn't apply.
        #expect(handBack(active: false, wasActive: false) == .none)
        #expect(handBack(active: true, userChoseOtherApp: true) == .activatePrevious(300))
    }

    // Menu bars (CG, top-left origin): main display 1728 wide with a 30 pt menu bar; a second one on the right.
    let menuBars = [CGRect(x: 0, y: 0, width: 1728, height: 30), CGRect(x: 1728, y: 0, width: 1920, height: 30)]

    func choosesOther(_ point: CGPoint, owner: pid_t?) -> Bool {
        ActivationHandOffPolicy.isClickChoosingAnotherApp(at: point, menuBars: menuBars, topWindowOwnerPID: owner,
                                                          targetPID: 200, ownPID: frost)
    }

    @Test func classifiesClicksDuringTheHandOff() {
        // Another app's window, the Dock / desktop (owner is Dock / Finder): the user chose another app.
        #expect(choosesOther(CGPoint(x: 300, y: 600), owner: 300))
        #expect(choosesOther(CGPoint(x: 900, y: 1100), owner: 77))
        // Unknown window owner (no window): also counts as clicking elsewhere.
        #expect(choosesOther(CGPoint(x: 300, y: 600), owner: nil))
        // Menu bar (empty spot, other icons; any display): just closes the popover.
        #expect(!choosesOther(CGPoint(x: 1070, y: 15), owner: 300))
        #expect(!choosesOther(CGPoint(x: 3000, y: 29), owner: nil))
        // The target app's own windows (the popover itself) and Frost's own windows.
        #expect(!choosesOther(CGPoint(x: 1400, y: 120), owner: 200))
        #expect(!choosesOther(CGPoint(x: 800, y: 400), owner: frost))
    }
}

