import Testing
import CoreGraphics
@testable import FrostCore

@Suite struct NewItemPlacementTests {
    func item(_ id: CGWindowID, _ bundle: String?, _ name: String = "Item-0", x: CGFloat = 0) -> MenuBarItem {
        // No window title: identities come from AX attributes (`identityKey`), which need no Screen Recording; the
        // clock is recognized by its AX identifier.
        MenuBarItem(windowID: id, frame: CGRect(x: x, y: 0, width: 29, height: 39), isOnScreen: false,
                    windowTitle: "", bundleID: bundle, pid: bundle == nil ? nil : 1, axDescription: nil,
                    axIdentifier: name == "Clock" ? SystemItemRules.clockIdentifier : nil,
                    identityKey: name.isEmpty ? nil : "desc:\(name)")
    }
    func id(_ bundle: String, _ name: String = "Item-0") -> ItemIdentity {
        ItemIdentity(bundleID: bundle, key: "desc:\(name)")
    }

    var layout: MenuBarLayout {
        [.alwaysHidden: [item(1, "com.a", x: -9000), item(2, "com.b", x: -8970)],
         .hidden: [item(3, "com.c", x: -3500), item(4, nil, x: -3470)],
         .visible: [item(5, "com.apple.controlcenter", "Clock", x: 1600)]]
    }

    @Test func firstScanSeedsEverythingPresentWithoutMoving() {
        let d = NewItemPlacement.decide(layout: layout, known: nil, considered: [])
        #expect(d.toMove.isEmpty)
        #expect(d.learned == [id("com.a"), id("com.b"), id("com.c"), id("com.apple.controlcenter", "Clock")])
        // Items with unresolved ownership are also marked as considered: they were present before seeding, so they
        // won't be moved once resolved either.
        #expect(d.considered == [1, 2, 3, 4, 5])
    }

    @Test func firstRunMovesPreexistingAlwaysHiddenItemsToHidden() {
        // Frost's first run: the system places existing icons without a Preferred Position left of AH (seed 10000).
        // The user can't have put anything in always-hidden yet, so move all of them to hidden; mark the rest as seen.
        let d = NewItemPlacement.decide(layout: layout, known: nil, considered: [], firstRun: true)
        #expect(d.toMove.map(\.windowID) == [1, 2])
        #expect(d.learned == [id("com.c"), id("com.apple.controlcenter", "Clock")])
        #expect(d.considered == [3, 5])
    }

    @Test func firstRunLeavesUnresolvedAndImmovableItemsForLater() {
        let mixed: MenuBarLayout = [.alwaysHidden: [item(1, nil, x: -9000),
                                                    item(2, "com.apple.controlcenter", "Clock", x: -8970),
                                                    item(3, "com.x", x: -8940)]]
        let d = NewItemPlacement.decide(layout: mixed, known: nil, considered: [], firstRun: true)
        #expect(d.toMove.map(\.windowID) == [3])
        // Unresolved items are not marked as considered: once resolved they are moved as "never-seen always-hidden items".
        #expect(!d.considered.contains(1))
        #expect(d.learned == [id("com.apple.controlcenter", "Clock")])
    }

    @Test func firstRunIsIgnoredOnceItemsAreKnown() {
        let known: Set = [id("com.a"), id("com.b"), id("com.c"), id("com.apple.controlcenter", "Clock")]
        let d = NewItemPlacement.decide(layout: layout, known: known, considered: [], firstRun: true)
        #expect(d.toMove.isEmpty)
    }

    @Test func neverSeenItemInAlwaysHiddenIsMoved() {
        let known: Set = [id("com.a"), id("com.c"), id("com.apple.controlcenter", "Clock")]
        let d = NewItemPlacement.decide(layout: layout, known: known, considered: [])
        #expect(d.toMove.map(\.windowID) == [2])
        // Items to move are marked as known only after the attempt.
        #expect(!d.learned.contains(id("com.b")))
        #expect(!d.considered.contains(2))
    }

    @Test func knownItemsInAlwaysHiddenStay() {
        // Icons the user put in always-hidden themselves (seen before) stay put.
        let known: Set = [id("com.a"), id("com.b"), id("com.c"), id("com.apple.controlcenter", "Clock")]
        let d = NewItemPlacement.decide(layout: layout, known: known, considered: [])
        #expect(d.toMove.isEmpty)
        #expect(d.learned.isEmpty)
    }

    @Test func newItemsElsewhereAreLearnedWithoutMoving() {
        let d = NewItemPlacement.decide(layout: layout, known: [id("com.a"), id("com.b")], considered: [])
        #expect(d.toMove.isEmpty)
        #expect(d.learned == [id("com.c"), id("com.apple.controlcenter", "Clock")])
        #expect(d.considered.isSuperset(of: [3, 5]))
    }

    @Test func unresolvedItemsWaitForOwnership() {
        // With ownership (or the identity key) unresolved we can't tell whether the icon was seen: leave it alone and
        // don't mark it as considered.
        let unresolved: MenuBarLayout = [.alwaysHidden: [item(1, nil), item(2, "com.x", "")]]
        let d = NewItemPlacement.decide(layout: unresolved, known: [], considered: [])
        #expect(d.toMove.isEmpty)
        #expect(d.learned.isEmpty)
        #expect(d.considered.isEmpty)
    }

    @Test func consideredItemsAreLearnedOnceResolvedButNeverMoved() {
        let d = NewItemPlacement.decide(layout: [.alwaysHidden: [item(1, "com.late")]], known: [], considered: [1])
        #expect(d.toMove.isEmpty)
        #expect(d.learned == [id("com.late")])
    }

    @Test func immovableItemsAreNotMoved() {
        let clock: MenuBarLayout = [.alwaysHidden: [item(1, "com.apple.controlcenter", "Clock")]]
        let d = NewItemPlacement.decide(layout: clock, known: [], considered: [])
        #expect(d.toMove.isEmpty)
        #expect(d.learned == [id("com.apple.controlcenter", "Clock")])
    }

    @Test func movesKeepLeftToRightOrder() {
        let two: MenuBarLayout = [.alwaysHidden: [item(7, "com.x", x: -9000), item(8, "com.y", x: -8970)]]
        #expect(NewItemPlacement.decide(layout: two, known: [], considered: []).toMove.map(\.windowID) == [7, 8])
    }

    @Test func identitiesRoundTripThroughJSON() throws {
        let known: Set = [id("com.a"), id("com.b", "Item-1")]
        let data = try NewItemPlacement.encode(known)
        #expect(try NewItemPlacement.decode(data) == known)
    }
}
