import Testing
import CoreGraphics
import Foundation
@testable import FrostCore

@Suite struct SectionKeeperTests {
    func item(_ id: CGWindowID, _ bundle: String?, _ name: String = "Item-0") -> MenuBarItem {
        // No window title: identities come from AX attributes (`identityKey`), which need no Screen Recording; the
        // clock is recognized by its AX identifier.
        MenuBarItem(windowID: id, frame: CGRect(x: CGFloat(id) * 30, y: 0, width: 29, height: 39), isOnScreen: false,
                    windowTitle: "", bundleID: bundle, pid: bundle == nil ? nil : 1, axDescription: nil,
                    axIdentifier: name == "Clock" ? SystemItemRules.clockIdentifier : nil,
                    identityKey: name.isEmpty ? nil : "desc:\(name)")
    }
    func id(_ bundle: String, _ name: String = "Item-0") -> ItemIdentity {
        ItemIdentity(bundleID: bundle, key: "desc:\(name)")
    }

    /// a and b in Always Hidden, c in Hidden, d and the clock in Visible.
    var layout: MenuBarLayout {
        [.alwaysHidden: [item(1, "com.a"), item(2, "com.b")],
         .hidden: [item(3, "com.c")],
         .visible: [item(4, "com.d"), item(5, "com.apple.controlcenter", "Clock")]]
    }

    // MARK: - Seeding

    @Test func firstObservationSeedsEveryResolvedMovableItem() {
        var keeper = SectionKeeper()
        let outcome = keeper.observe(layout: layout, restoreEnabled: true, canMove: true)
        #expect(outcome.restores.isEmpty)
        #expect(outcome.userMoves.isEmpty)
        #expect(keeper.memory == [id("com.a"): .alwaysHidden, id("com.b"): .alwaysHidden, id("com.c"): .hidden,
                                  id("com.d"): .visible])
        #expect(outcome.seeded == Set(keeper.memory.keys))
        #expect(keeper.unsettled.isEmpty)
        #expect(keeper.observed == [1: .alwaysHidden, 2: .alwaysHidden, 3: .hidden, 4: .visible, 5: .visible])
    }

    @Test func seedingNeverOverwritesExistingEntries() {
        // Remembered: a in Hidden. a's window is new to this run, so it is restored rather than re-seeded.
        var keeper = SectionKeeper(memory: [id("com.a"): .hidden])
        let outcome = keeper.observe(layout: layout, restoreEnabled: true, canMove: true)
        #expect(keeper.memory[id("com.a")] == .hidden)
        #expect(!outcome.seeded.contains(id("com.a")))
        #expect(outcome.restores.map(\.item.windowID) == [1])
    }

    @Test func seedingSkipsTheMemoryWhenDisabledToo() {
        // The setting only turns restoring off; the memory is still kept up to date.
        var keeper = SectionKeeper()
        let outcome = keeper.observe(layout: layout, restoreEnabled: false, canMove: true)
        #expect(outcome.seeded.count == 4)
    }

    // MARK: - Restoring

    @Test func newWindowInAnotherSectionIsRestored() {
        var keeper = SectionKeeper()
        _ = keeper.observe(layout: layout, restoreEnabled: true, canMove: true)
        // c's app relaunches: window 3 is gone, the new window 13 lands in Always Hidden.
        let relaunched: MenuBarLayout = [.alwaysHidden: [item(13, "com.c"), item(1, "com.a"), item(2, "com.b")],
                                         .hidden: [],
                                         .visible: [item(4, "com.d"), item(5, "com.apple.controlcenter", "Clock")]]
        let outcome = keeper.observe(layout: relaunched, restoreEnabled: true, canMove: true)
        #expect(outcome.restores == [SectionKeeper.Restore(item: item(13, "com.c"), identity: id("com.c"),
                                                           from: .alwaysHidden, to: .hidden)])
        #expect(keeper.observed[3] == nil)
        #expect(keeper.unsettled == [13])
        #expect(keeper.memory[id("com.c")] == .hidden)

        // The restore moved it (Frost's own move): no user move, nothing pending.
        keeper.restoreAttempted(13)
        let restored: MenuBarLayout = [.alwaysHidden: [item(1, "com.a"), item(2, "com.b")],
                                       .hidden: [item(13, "com.c")],
                                       .visible: [item(4, "com.d"), item(5, "com.apple.controlcenter", "Clock")]]
        let after = keeper.observe(layout: restored, movedByFrost: [13], restoreEnabled: true, canMove: true)
        #expect(after == SectionKeeper.Outcome())
        #expect(keeper.memory[id("com.c")] == .hidden)
        #expect(keeper.unsettled.isEmpty)
    }

    @Test func restoresIntoVisibleAndAlwaysHiddenToo() {
        var keeper = SectionKeeper(memory: [id("com.a"): .visible, id("com.c"): .alwaysHidden])
        let outcome = keeper.observe(layout: layout, restoreEnabled: true, canMove: true)
        #expect(outcome.restores.map(\.item.windowID) == [1, 3])
        #expect(outcome.restores.map(\.to) == [.visible, .alwaysHidden])
    }

    @Test func newWindowInItsRememberedSectionStays() {
        var keeper = SectionKeeper(memory: [id("com.a"): .alwaysHidden, id("com.c"): .hidden])
        let outcome = keeper.observe(layout: layout, restoreEnabled: true, canMove: true)
        #expect(outcome.restores.isEmpty)
        #expect(keeper.unsettled.isEmpty)
    }

    @Test func failedRestoreIsNotRetried() {
        var keeper = SectionKeeper(memory: [id("com.a"): .hidden])
        let result = keeper.observe(layout: layout, restoreEnabled: true, canMove: true)
        #expect(result.restores.count == 1)
        keeper.restoreAttempted(1)
        // Still in Always Hidden (the move failed): checked, nothing recorded.
        let again = keeper.observe(layout: layout, restoreEnabled: true, canMove: true)
        #expect(again.restores.isEmpty)
        #expect(again.userMoves.isEmpty)
        #expect(keeper.memory[id("com.a")] == .hidden)
    }

    @Test func restoreWaitsUntilMovingIsPossible() {
        var keeper = SectionKeeper(memory: [id("com.a"): .hidden])
        let expanded = keeper.observe(layout: layout, restoreEnabled: true, canMove: false)
        #expect(expanded.restores.isEmpty)
        #expect(keeper.unsettled == [1])
        let collapsed = keeper.observe(layout: layout, restoreEnabled: true, canMove: true)
        #expect(collapsed.restores.map(\.item.windowID) == [1])
    }

    @Test func pendingWindowMovedByTheUserIsNotRestored() {
        // The window showed up displaced while Frost couldn't move; before it could, the user put it somewhere else:
        // that is now where it belongs.
        var keeper = SectionKeeper(memory: [id("com.a"): .hidden])
        _ = keeper.observe(layout: layout, restoreEnabled: true, canMove: false)
        let moved: MenuBarLayout = [.alwaysHidden: [item(2, "com.b")], .hidden: [item(3, "com.c")],
                                    .visible: [item(1, "com.a"), item(4, "com.d")]]
        let outcome = keeper.observe(layout: moved, restoreEnabled: true, canMove: true)
        #expect(outcome.restores.isEmpty)
        #expect(outcome.userMoves == [SectionKeeper.UserMove(identity: id("com.a"), from: .alwaysHidden, to: .visible)])
        #expect(keeper.memory[id("com.a")] == .visible)
        #expect(keeper.unsettled.isEmpty)
    }

    // MARK: - The setting

    @Test func disabledAcceptsDisplacedWindowsWhereTheyAre() {
        var keeper = SectionKeeper(memory: [id("com.a"): .hidden])
        let outcome = keeper.observe(layout: layout, restoreEnabled: false, canMove: true)
        #expect(outcome.restores.isEmpty)
        #expect(keeper.unsettled.isEmpty)
        // The memory keeps the user's choice (turning the setting back on applies to the next relaunch).
        #expect(keeper.memory[id("com.a")] == .hidden)
        let result = keeper.observe(layout: layout, restoreEnabled: true, canMove: true)
        #expect(result.restores.isEmpty)
    }

    @Test func disabledStillRecordsUserMoves() {
        var keeper = SectionKeeper()
        _ = keeper.observe(layout: layout, restoreEnabled: false, canMove: true)
        let moved: MenuBarLayout = [.alwaysHidden: [item(1, "com.a"), item(2, "com.b")], .hidden: [],
                                    .visible: [item(3, "com.c"), item(4, "com.d")]]
        let outcome = keeper.observe(layout: moved, restoreEnabled: false, canMove: true)
        #expect(outcome.userMoves.map(\.to) == [.visible])
        #expect(keeper.memory[id("com.c")] == .visible)
    }

    // MARK: - User moves

    @Test func sameWindowChangingSectionIsAUserMoveNotARestore() {
        var keeper = SectionKeeper()
        _ = keeper.observe(layout: layout, restoreEnabled: true, canMove: true)
        // The user ⌘-drags d (Visible) into Hidden and a (Always Hidden) into Visible.
        let moved: MenuBarLayout = [.alwaysHidden: [item(2, "com.b")], .hidden: [item(3, "com.c"), item(4, "com.d")],
                                    .visible: [item(1, "com.a"), item(5, "com.apple.controlcenter", "Clock")]]
        let outcome = keeper.observe(layout: moved, restoreEnabled: true, canMove: true)
        #expect(outcome.restores.isEmpty)
        #expect(outcome.userMoves == [
            SectionKeeper.UserMove(identity: id("com.d"), from: .visible, to: .hidden),
            SectionKeeper.UserMove(identity: id("com.a"), from: .alwaysHidden, to: .visible),
        ])
        #expect(keeper.memory[id("com.d")] == .hidden)
        #expect(keeper.memory[id("com.a")] == .visible)
        #expect(outcome.memoryChanged)
    }

    @Test func userMoveIsThenRestoredOnRelaunch() {
        var keeper = SectionKeeper()
        _ = keeper.observe(layout: layout, restoreEnabled: true, canMove: true)
        let moved: MenuBarLayout = [.alwaysHidden: [item(2, "com.b")], .hidden: [item(3, "com.c")],
                                    .visible: [item(1, "com.a"), item(4, "com.d")]]
        _ = keeper.observe(layout: moved, restoreEnabled: true, canMove: true)
        // a's app relaunches into Always Hidden.
        let relaunched: MenuBarLayout = [.alwaysHidden: [item(11, "com.a"), item(2, "com.b")],
                                         .hidden: [item(3, "com.c")], .visible: [item(4, "com.d")]]
        let outcome = keeper.observe(layout: relaunched, restoreEnabled: true, canMove: true)
        #expect(outcome.restores.map(\.to) == [.visible])
    }

    @Test func changesFrostMadeAreNotUserMoves() {
        // E.g. a Frost Bar click forward whose move-back failed left the item in Visible.
        var keeper = SectionKeeper()
        _ = keeper.observe(layout: layout, restoreEnabled: true, canMove: true)
        let moved: MenuBarLayout = [.alwaysHidden: [item(1, "com.a"), item(2, "com.b")], .hidden: [],
                                    .visible: [item(3, "com.c"), item(4, "com.d")]]
        let outcome = keeper.observe(layout: moved, movedByFrost: [3], restoreEnabled: true, canMove: true)
        #expect(outcome == SectionKeeper.Outcome())
        #expect(keeper.memory[id("com.c")] == .hidden)
        #expect(keeper.observed[3] == .visible)
        // And it isn't "restored" either: the window isn't new.
        let result = keeper.observe(layout: moved, restoreEnabled: true, canMove: true)
        #expect(result.restores.isEmpty)
    }

    @Test func explicitRecordUpdatesTheMemory() {
        var keeper = SectionKeeper()
        _ = keeper.observe(layout: layout, restoreEnabled: true, canMove: true)
        let items = layout.values.flatMap { $0 }
        let result = keeper.record(item(4, "com.d"), in: .alwaysHidden, among: items)
        #expect(result)
        #expect(keeper.memory[id("com.d")] == .alwaysHidden)
        // Unresolved items can't be recorded.
        let unresolved = keeper.record(item(9, nil), in: .hidden, among: items)
        #expect(!unresolved)
    }

    // MARK: - Ambiguity, unresolved and obscured items

    @Test func ambiguousIdentitiesAreNeitherRestoredNorRecorded() {
        var keeper = SectionKeeper(memory: [id("com.x"): .hidden])
        let twins: MenuBarLayout = [.alwaysHidden: [item(1, "com.x"), item(2, "com.x")], .hidden: [], .visible: []]
        let outcome = keeper.observe(layout: twins, restoreEnabled: true, canMove: true)
        #expect(outcome.restores.isEmpty)
        #expect(outcome.ambiguous == [id("com.x")])
        #expect(keeper.observed.isEmpty)
        let result = keeper.record(item(1, "com.x"), in: .visible, among: twins.values.flatMap { $0 })
        #expect(!result)
        #expect(keeper.memory == [id("com.x"): .hidden])
    }

    @Test func ambiguityEndingLetsTheRemainingWindowBeChecked() {
        // The app re-created its item and the old window lingered for a moment.
        var keeper = SectionKeeper()
        _ = keeper.observe(layout: [.hidden: [item(1, "com.x")]], restoreEnabled: true, canMove: true)
        let both: MenuBarLayout = [.alwaysHidden: [item(2, "com.x")], .hidden: [item(1, "com.x")]]
        let result = keeper.observe(layout: both, restoreEnabled: true, canMove: true)
        #expect(result.restores.isEmpty)
        let onlyNew: MenuBarLayout = [.alwaysHidden: [item(2, "com.x")], .hidden: []]
        let outcome = keeper.observe(layout: onlyNew, restoreEnabled: true, canMove: true)
        #expect(outcome.restores.map(\.item.windowID) == [2])
        #expect(outcome.restores.map(\.to) == [.hidden])
    }

    @Test func knownWindowMovedWhileAmbiguousIsNotRecorded() {
        var keeper = SectionKeeper()
        _ = keeper.observe(layout: [.hidden: [item(1, "com.x")]], restoreEnabled: true, canMove: true)
        let both: MenuBarLayout = [.visible: [item(1, "com.x"), item(2, "com.x")]]
        let outcome = keeper.observe(layout: both, restoreEnabled: true, canMove: true)
        #expect(outcome.userMoves.isEmpty)
        #expect(keeper.memory[id("com.x")] == .hidden)
        #expect(keeper.observed[1] == .visible)
    }

    @Test func unresolvedItemsWaitUntilResolved() {
        var keeper = SectionKeeper(memory: [id("com.x"): .hidden])
        let unresolved: MenuBarLayout = [.alwaysHidden: [item(1, nil), item(2, "com.x", "")]]
        let first = keeper.observe(layout: unresolved, restoreEnabled: true, canMove: true)
        #expect(first == SectionKeeper.Outcome())
        #expect(keeper.observed.isEmpty)
        let resolved: MenuBarLayout = [.alwaysHidden: [item(1, "com.x"), item(2, "com.y", "Item-1")]]
        let outcome = keeper.observe(layout: resolved, restoreEnabled: true, canMove: true)
        #expect(outcome.restores.map(\.item.windowID) == [1])
        #expect(outcome.seeded == [id("com.y", "Item-1")])
    }

    @Test func obscuredItemsAreSkipped() {
        var keeper = SectionKeeper()
        _ = keeper.observe(layout: layout, restoreEnabled: true, canMove: true)
        // Item 4 is under the notch and its x says Hidden: not a user move.
        let notched: MenuBarLayout = [.alwaysHidden: [item(1, "com.a"), item(2, "com.b")],
                                      .hidden: [item(3, "com.c"), item(4, "com.d")], .visible: []]
        let outcome = keeper.observe(layout: notched, obscured: [4], restoreEnabled: true, canMove: true)
        #expect(outcome.userMoves.isEmpty)
        #expect(keeper.observed[4] == .visible)
        #expect(keeper.memory[id("com.d")] == .visible)
    }

    @Test func skippedWindowsAreLeftUnseen() {
        // A never-seen icon the new-item placement is moving to Hidden: not seeded as Always Hidden.
        var keeper = SectionKeeper()
        let outcome = keeper.observe(layout: layout, skipping: [2], restoreEnabled: true, canMove: true)
        #expect(!outcome.seeded.contains(id("com.b")))
        #expect(keeper.observed[2] == nil)
    }

    @Test func immovableItemsAreNeverRecordedOrRestored() {
        var keeper = SectionKeeper(memory: [id("com.apple.controlcenter", "Clock"): .hidden])
        let outcome = keeper.observe(layout: layout, restoreEnabled: true, canMove: true)
        #expect(!outcome.restores.contains { $0.item.windowID == 5 })
        #expect(!outcome.seeded.contains(id("com.apple.controlcenter", "Clock")))
    }

    @Test func vanishedWindowsAreForgotten() {
        var keeper = SectionKeeper()
        _ = keeper.observe(layout: layout, restoreEnabled: true, canMove: true)
        _ = keeper.observe(layout: [.hidden: [item(3, "com.c")]], restoreEnabled: true, canMove: true)
        #expect(keeper.observed == [3: .hidden])
        // The memory outlives the windows.
        #expect(keeper.memory.count == 4)
    }

    @Test(arguments: [CGWindowID(1), 9])
    func anItemThatVanishesBrieflyKeepsItsSection(returningAs windowID: CGWindowID) {
        // A chat-app-like item disappears for a scan or two (its icon blinking) and comes back, as the same window or a
        // new one, first without an owner (a new window waits for the next AX read). Nothing is seeded, restored or
        // recorded as a user move, and the memory stays as it was.
        var keeper = SectionKeeper(memory: [id("com.a"): .alwaysHidden, id("com.c"): .hidden])
        _ = keeper.observe(layout: layout, restoreEnabled: true, canMove: true)
        let memory = keeper.memory
        let without: MenuBarLayout = [.alwaysHidden: [item(2, "com.b")], .hidden: [item(3, "com.c")]]
        for _ in 0..<2 {
            #expect(keeper.observe(layout: without, restoreEnabled: true, canMove: true) == .init())
        }
        let unresolved: MenuBarLayout = [.alwaysHidden: [item(windowID, nil, ""), item(2, "com.b")],
                                         .hidden: [item(3, "com.c")]]
        #expect(keeper.observe(layout: unresolved, restoreEnabled: true, canMove: true) == .init())
        let back: MenuBarLayout = [.alwaysHidden: [item(windowID, "com.a"), item(2, "com.b")],
                                   .hidden: [item(3, "com.c")]]
        #expect(keeper.observe(layout: back, restoreEnabled: true, canMove: true) == .init())
        #expect(keeper.memory == memory)
        #expect(keeper.unsettled.isEmpty)
    }

    // MARK: - Destinations and persistence

    @Test func destinationsAreTheSectionBoundaries() {
        let controls = FrostControlWindows(icon: 100, hiddenSeparator: 101, alwaysHiddenSeparator: 102)
        #expect(SectionKeeper.destination(for: .hidden, controls: controls) == .leftOf(101))
        #expect(SectionKeeper.destination(for: .alwaysHidden, controls: controls) == .leftOf(102))
        #expect(SectionKeeper.destination(for: .visible, controls: controls) == .rightOf(100))
    }

    @Test func separatorReliability() {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        func separator(x: CGFloat, width: CGFloat, onScreen: Bool) -> MenuBarItem {
            MenuBarItem(windowID: 101, frame: CGRect(x: x, y: 0, width: width, height: 39), isOnScreen: onScreen,
                        windowTitle: "", bundleID: nil, pid: nil, axDescription: nil)
        }
        // Collapsed: the 5016 pt wide separator reaches into the display but is onscreen=false.
        #expect(SectionKeeper.separatorIsReliable(separator(x: -3600, width: 5016, onScreen: false),
                                                  displayBounds: display))
        // Pushed entirely off the left edge.
        #expect(SectionKeeper.separatorIsReliable(separator(x: -8600, width: 5016, onScreen: false),
                                                  displayBounds: display))
        // Expanded and visible.
        #expect(SectionKeeper.separatorIsReliable(separator(x: 1200, width: 1, onScreen: true), displayBounds: display))
        // Expanded but squeezed under the notch.
        #expect(!SectionKeeper.separatorIsReliable(separator(x: 800, width: 16, onScreen: false),
                                                   displayBounds: display))
    }

    @Test func memoryRoundTripsSorted() throws {
        let memory: [ItemIdentity: MenuBarSection] = [id("com.b"): .visible, id("com.a", "Item-1"): .alwaysHidden,
                                                      id("com.a"): .hidden]
        let data = try SectionKeeper.encode(memory)
        #expect(try SectionKeeper.decode(data) == memory)
        let entries = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: String]])
        #expect(entries == [["bundleID": "com.a", "key": "desc:Item-0", "section": "hidden"],
                            ["bundleID": "com.a", "key": "desc:Item-1", "section": "alwaysHidden"],
                            ["bundleID": "com.b", "key": "desc:Item-0", "section": "visible"]])
    }

    @Test func version1MemoryIsReadAsLegacyIdentities() throws {
        let v1 = Data(#"[{"bundleID":"com.a","title":"Item-0","section":"hidden"}]"#.utf8)
        #expect(try SectionKeeper.decodeLegacy(v1)
                == [IdentityMigration.legacy(bundleID: "com.a", title: "Item-0"): .hidden])
        // The version 2 reader doesn't mistake version 1 data for its own.
        #expect(throws: (any Error).self) { try SectionKeeper.decode(v1) }
    }

    @Test func rekeyMovesRememberedSections() {
        let legacy = IdentityMigration.legacy(bundleID: "com.a", title: "Item-0")
        var keeper = SectionKeeper(memory: [legacy: .visible, id("com.b"): .hidden])
        let changed = keeper.rekey([legacy: id("com.a")])
        #expect(changed)
        #expect(keeper.memory == [id("com.a"): .visible, id("com.b"): .hidden])
        let changedAgain = keeper.rekey([:])
        #expect(!changedAgain)
    }

    @Test func migratedMemoryRestoresAfterRelaunchWithoutTitles() {
        // Remembered before identity keys existed (with Screen Recording): com.a in Visible.
        let legacy = IdentityMigration.legacy(bundleID: "com.a", title: "Item-0")
        var keeper = SectionKeeper(memory: [legacy: .visible])
        // First launch of the new version, titles readable: the legacy entry moves to the AX-derived identity.
        let titled = MenuBarItem(windowID: 1, frame: .zero, isOnScreen: true, windowTitle: "Item-0", bundleID: "com.a",
                                 pid: 1, axDescription: nil, identityKey: "desc:Item-0")
        keeper.rekey(IdentityMigration.plan(stored: Set(keeper.memory.keys), items: [titled]))
        #expect(keeper.memory == [id("com.a"): .visible])
        // Later, without Screen Recording, the app relaunches and macOS re-adds its icon in Always Hidden.
        let outcome = keeper.observe(layout: [.alwaysHidden: [item(9, "com.a")]], restoreEnabled: true, canMove: true)
        #expect(outcome.restores.map(\.to) == [.visible])
    }

    // MARK: Pending returns (Frost quit before moving an item back)

    @Test func aPendingReturnMovesTheItemBackOnTheNextLaunchEvenWithKeepingOff() {
        var keeper = SectionKeeper(memory: [id("com.a"): .visible],
                                   pendingReturns: [id("com.a"): PendingReturn(section: .hidden)])
        let outcome = keeper.observe(layout: [.visible: [item(1, "com.a")]], restoreEnabled: false, canMove: true)
        #expect(outcome.restores == [SectionKeeper.Restore(item: item(1, "com.a"), identity: id("com.a"),
                                                           from: .visible, to: .hidden,
                                                           slot: PendingReturn(section: .hidden))])
        let changed = keeper.restoreAttempted(1, identity: id("com.a"))
        #expect(changed)
        #expect(keeper.pendingReturns.isEmpty)
        // Not tried again.
        let again = keeper.observe(layout: [.visible: [item(1, "com.a")]], restoreEnabled: false, canMove: true)
        #expect(again.restores.isEmpty)
    }

    @Test func aPendingReturnWaitsUntilMovingIsPossible() {
        var keeper = SectionKeeper(pendingReturns: [id("com.a"): PendingReturn(section: .alwaysHidden)])
        let waiting = keeper.observe(layout: [.visible: [item(1, "com.a")]], restoreEnabled: true, canMove: false)
        #expect(waiting.restores.isEmpty)
        #expect(waiting.seeded.isEmpty)
        let now = keeper.observe(layout: [.visible: [item(1, "com.a")]], restoreEnabled: true, canMove: true)
        #expect(now.restores.map(\.to) == [.alwaysHidden])
    }

    @Test func aPendingReturnFoundInPlaceIsDropped() {
        var keeper = SectionKeeper(pendingReturns: [id("com.a"): PendingReturn(section: .hidden)])
        let outcome = keeper.observe(layout: [.hidden: [item(1, "com.a")]], restoreEnabled: true, canMove: true)
        #expect(outcome.restores.isEmpty)
        #expect(outcome.pendingReturnsChanged)
        #expect(keeper.pendingReturns.isEmpty)
    }

    // MARK: Accessibility-only upgrade, then Screen Recording (two launches)

    /// One launch's pass as `NewItemPlacer` makes it: migrate, then observe without seeding identities that may still
    /// migrate; returns the memory as persisted.
    func launch(memory: Data, items: [MenuBarItem], layouts: [MenuBarLayout]) throws -> (Data, [SectionKeeper.Outcome]) {
        var keeper = SectionKeeper(memory: try SectionKeeper.decode(memory))
        keeper.rekey(IdentityMigration.plan(stored: Set(keeper.memory.keys), items: items))
        let outcomes = layouts.map { layout in
            keeper.observe(layout: layout,
                           awaitingMigration: IdentityMigration.awaitingMigration(stored: Set(keeper.memory.keys),
                                                                                  items: items),
                           restoreEnabled: true, canMove: true)
        }
        return (try SectionKeeper.encode(keeper.memory), outcomes)
    }

    func app(_ windowID: CGWindowID, key: String, title: String) -> MenuBarItem {
        MenuBarItem(windowID: windowID, frame: CGRect(x: CGFloat(windowID) * 30, y: 0, width: 29, height: 39),
                    isOnScreen: false, windowTitle: title, bundleID: "com.a", pid: 1, axDescription: nil,
                    identityKey: key)
    }

    @Test func anAccessibilityOnlyLaunchDoesNotBlockTheLaterMigration() throws {
        // Remembered by title (an earlier version with Screen Recording): the app's two items in Visible and Hidden.
        let v1 = try SectionKeeper.encode([IdentityMigration.legacy(bundleID: "com.a", title: "Item-0"): .visible,
                                           IdentityMigration.legacy(bundleID: "com.a", title: "Item-1"): .hidden])
        // Launch 1, Accessibility only: the app re-created both in Always Hidden; titles unreadable, so which is which
        // can't be told yet.
        let blind = [app(1, key: "desc:A", title: ""), app(2, key: "desc:B", title: "")]
        let (afterBlind, first) = try launch(memory: v1, items: blind, layouts: [[.alwaysHidden: blind]])
        #expect(first[0].seeded.isEmpty)
        #expect(first[0].restores.isEmpty)
        #expect(try SectionKeeper.decode(afterBlind) == SectionKeeper.decode(v1))
        // Launch 2, Screen Recording granted: titles map the remembered sections, which are restored.
        let titled = [app(11, key: "desc:A", title: "Item-0"), app(12, key: "desc:B", title: "Item-1")]
        let (afterTitled, second) = try launch(memory: afterBlind, items: titled, layouts: [[.alwaysHidden: titled]])
        #expect(Set(second[0].restores.map { "\($0.item.windowID)->\($0.to.rawValue)" })
                == ["11->\(MenuBarSection.visible.rawValue)", "12->\(MenuBarSection.hidden.rawValue)"])
        #expect(try SectionKeeper.decode(afterTitled) == [ItemIdentity(bundleID: "com.a", key: "desc:A"): .visible,
                                                          ItemIdentity(bundleID: "com.a", key: "desc:B"): .hidden])
    }

    @Test func aMoveTheUserMakesMeanwhileWinsOverTheMigration() throws {
        let v1 = try SectionKeeper.encode([IdentityMigration.legacy(bundleID: "com.a", title: "Item-0"): .visible,
                                           IdentityMigration.legacy(bundleID: "com.a", title: "Item-1"): .hidden])
        let blind = [app(1, key: "desc:A", title: ""), app(2, key: "desc:B", title: "")]
        // B is seen in Always Hidden, then the user moves it to Visible: their choice, recorded.
        let (afterBlind, first) = try launch(memory: v1, items: blind, layouts: [
            [.alwaysHidden: blind], [.alwaysHidden: [blind[0]], .visible: [blind[1]]],
        ])
        #expect(first[1].userMoves.map(\.to) == [.visible])
        let titled = [app(11, key: "desc:A", title: "Item-0"), app(12, key: "desc:B", title: "Item-1")]
        let (afterTitled, _) = try launch(memory: afterBlind, items: titled, layouts: [[.alwaysHidden: titled]])
        let memory = try SectionKeeper.decode(afterTitled)
        #expect(memory[ItemIdentity(bundleID: "com.a", key: "desc:A")] == .visible)
        #expect(memory[ItemIdentity(bundleID: "com.a", key: "desc:B")] == .visible)
    }

    @Test func unreadableMemoryThrows() {
        #expect(throws: (any Error).self) { try SectionKeeper.decode(Data("{}".utf8)) }
        #expect(throws: (any Error).self) {
            try SectionKeeper.decode(Data(#"[{"bundleID":"a","key":"b","section":"elsewhere"}]"#.utf8))
        }
    }
}
