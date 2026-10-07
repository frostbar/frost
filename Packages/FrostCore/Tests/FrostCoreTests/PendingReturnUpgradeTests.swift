import Testing
import CoreGraphics
import Foundation
@testable import FrostCore

/// Upgrades of the pending returns (icons the background capture of items behind the notch had moved out when Frost
/// quit), driven through the launch path: `ItemMemoryStore` loading a `UserDefaults` suite seeded exactly as an earlier
/// release stored it, a decision as `NewItemPlacer.evaluate` makes it, the moves as `NewItemPlacer.move` makes them
/// (each restore's destination from `SectionKeeper.Restore.destination`, then `restoresAttempted`), and the next
/// launches changing nothing.
@MainActor
@Suite struct PendingReturnUpgradeTests {
    let suiteName = "PendingReturnUpgradeTests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let controls = FrostControlWindows(icon: 100, hiddenSeparator: 101, alwaysHiddenSeparator: 102)

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    var stored: NSDictionary { NSDictionary(dictionary: defaults.persistentDomain(forName: suiteName) ?? [:]) }

    func seed(_ json: String, forKey key: String) {
        defaults.set(Data(json.utf8), forKey: key)
    }

    func item(_ windowID: CGWindowID, _ name: String) -> MenuBarItem {
        MenuBarItem(windowID: windowID, frame: CGRect(x: CGFloat(windowID) * 30, y: 0, width: 29, height: 24),
                    isOnScreen: true, windowTitle: "", bundleID: "com.example.\(name)", pid: 1, axDescription: nil,
                    identityKey: "desc:\(name)")
    }

    func id(_ name: String) -> ItemIdentity { ItemIdentity(bundleID: "com.example.\(name)", key: "desc:\(name)") }

    /// One launch: a decision of `NewItemPlacer.evaluate` on a trusted, collapsed layout, then the moves it asks for.
    /// Returns each restored window's destination.
    func launch(_ layout: MenuBarLayout) -> [CGWindowID: MoveDestination] {
        let store = ItemMemoryStore(defaults: defaults)
        let items = MenuBarSection.leftToRight.flatMap { layout[$0, default: []] }
        store.migrateIdentities(items)
        let decision = store.decideNewItems(layout: layout, items: items, considered: [])
        let outcome = store.observeSections(layout: layout, items: items, obscured: [], movedByFrost: [],
                                            skipping: Set(decision.toMove.map(\.windowID)), restoreEnabled: true,
                                            canMove: true)
        var moves: [CGWindowID: MoveDestination] = [:]
        for restore in outcome.restores {
            moves[restore.item.windowID] = restore.destination(in: layout, controls: controls)
        }
        store.restoresAttempted(outcome.restores.map(\.item))
        return moves
    }

    // MARK: - From 0.3.2

    /// Stored by 0.3.2 when Frost quit while background captures held two icons out (`SectionKeeper.encode` under
    /// `pendingItemReturns.v1`, next to the remembered sections and the seen icons): D from Hidden, A from Always Hidden.
    func seed032() {
        seed("""
            [{"bundleID":"com.example.A","key":"desc:A"},{"bundleID":"com.example.B","key":"desc:B"},\
            {"bundleID":"com.example.C","key":"desc:C"},{"bundleID":"com.example.D","key":"desc:D"},\
            {"bundleID":"com.example.E","key":"desc:E"}]
            """, forKey: "knownItemIdentities.v2")
        seed("""
            [{"bundleID":"com.example.A","key":"desc:A","section":"alwaysHidden"},\
            {"bundleID":"com.example.B","key":"desc:B","section":"alwaysHidden"},\
            {"bundleID":"com.example.C","key":"desc:C","section":"hidden"},\
            {"bundleID":"com.example.D","key":"desc:D","section":"hidden"},\
            {"bundleID":"com.example.E","key":"desc:E","section":"hidden"}]
            """, forKey: "itemSections.v2")
        seed("""
            [{"bundleID":"com.example.A","key":"desc:A","section":"alwaysHidden"},\
            {"bundleID":"com.example.D","key":"desc:D","section":"hidden"}]
            """, forKey: "pendingItemReturns.v1")
    }

    /// Protects the upgrade from 0.3.2: its pending returns carry no slot, so each icon goes back to its section's edge
    /// (as 0.3.2 did), once; the entries are dropped and the next launches change nothing.
    @Test func pendingReturnsFrom032GoBackToTheSectionEdgeOnce() throws {
        defer { cleanUp() }
        seed032()
        let a = item(1, "A"), b = item(2, "B"), c = item(3, "C"), d = item(4, "D"), e = item(5, "E")
        // Both icons are where the move out left them: right of the Frost icon.
        #expect(launch([.alwaysHidden: [b], .hidden: [c, e], .visible: [d, a]]) == [1: .leftOf(102), 4: .leftOf(101)])
        #expect(defaults.data(forKey: "pendingItemReturns.v1") == nil)

        let restored: MenuBarLayout = [.alwaysHidden: [b, a], .hidden: [c, e, d], .visible: []]
        let before = stored
        #expect(launch(restored).isEmpty)
        #expect(launch(restored).isEmpty)
        #expect(stored == before)
    }

    // MARK: - Recorded by this release

    /// A pending return recorded now goes back to its exact slot on the next launch, by its neighbours' identities (the
    /// windows are new).
    @Test func pendingReturnsRecordedNowGoBackToTheirExactSlot() throws {
        defer { cleanUp() }
        let a = item(1, "A"), b = item(2, "B"), c = item(3, "C"), d = item(4, "D"), e = item(5, "E")
        let before: MenuBarLayout = [.alwaysHidden: [a, b], .hidden: [c, d, e], .visible: []]
        let items = MenuBarSection.leftToRight.flatMap { before[$0, default: []] }
        let run = ItemMemoryStore(defaults: defaults)
        _ = run.decideNewItems(layout: before, items: items, considered: [])
        _ = run.observeSections(layout: before, items: items, obscured: [], movedByFrost: [], skipping: [],
                                restoreEnabled: true, canMove: true)
        // Frost moves D and A out and quits before moving them back.
        #expect(run.notePendingReturn(of: d, in: before, among: items) == id("D"))
        #expect(run.notePendingReturn(of: a, in: before, among: items) == id("A"))

        // Next launch: every app re-created its window (new IDs); D and A sit right of the Frost icon.
        let a2 = item(11, "A"), b2 = item(12, "B"), c2 = item(13, "C"), d2 = item(14, "D"), e2 = item(15, "E")
        #expect(launch([.alwaysHidden: [b2], .hidden: [c2, e2], .visible: [d2, a2]]) == [14: .leftOf(15), 11: .leftOf(12)])
        #expect(defaults.data(forKey: "pendingItemReturns.v1") == nil)

        let after = stored
        #expect(launch([.alwaysHidden: [a2, b2], .hidden: [c2, d2, e2], .visible: []]).isEmpty)
        #expect(stored == after)
    }

    @Test func aPendingReturnWhoseNeighboursAreGoneGoesToTheSectionEdge() throws {
        defer { cleanUp() }
        seed("""
            [{"bundleID":"com.example.D","key":"desc:D","section":"hidden",\
            "right":{"bundleID":"com.example.E","key":"desc:E"},"left":{"bundleID":"com.example.C","key":"desc:C"}}]
            """, forKey: "pendingItemReturns.v1")
        // Neither C's nor E's app is running.
        #expect(launch([.alwaysHidden: [], .hidden: [item(6, "X")], .visible: [item(4, "D")]]) == [4: .leftOf(101)])
    }
}
