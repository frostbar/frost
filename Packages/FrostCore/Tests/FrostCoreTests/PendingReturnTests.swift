import Testing
import CoreGraphics
import Foundation
@testable import FrostCore

@Suite struct PendingReturnTests {
    let controls = FrostControlWindows(icon: 100, hiddenSeparator: 101, alwaysHiddenSeparator: 102)

    func item(_ windowID: CGWindowID, _ name: String?, bundleID: String = "com.example.app") -> MenuBarItem {
        MenuBarItem(windowID: windowID, frame: CGRect(x: CGFloat(windowID) * 30, y: 0, width: 29, height: 24),
                    isOnScreen: false, windowTitle: "", bundleID: bundleID, pid: 1, axDescription: nil,
                    identityKey: name.map { "desc:\($0)" })
    }

    func id(_ name: String, bundleID: String = "com.example.app") -> ItemIdentity {
        ItemIdentity(bundleID: bundleID, key: "desc:\(name)")
    }

    // MARK: - Recording the slot

    @Test func recordsTheNeighboursWithinTheSection() throws {
        let layout: MenuBarLayout = [.alwaysHidden: [item(1, "A")], .hidden: [item(2, "B"), item(3, "C"), item(4, "D")],
                                     .visible: [item(5, "E")]]
        let pending = try #require(PendingReturn.make(for: item(3, "C"), in: layout))
        #expect(pending == PendingReturn(section: .hidden, rightNeighbour: id("D"), leftNeighbour: id("B")))
    }

    @Test func neighboursNeverCrossSections() throws {
        // B is the leftmost Hidden item: A (Always Hidden) is not its left neighbour, D (Visible) not C's right one.
        let layout: MenuBarLayout = [.alwaysHidden: [item(1, "A")], .hidden: [item(2, "B"), item(3, "C")],
                                     .visible: [item(4, "D")]]
        #expect(PendingReturn.make(for: item(2, "B"), in: layout)
                == PendingReturn(section: .hidden, rightNeighbour: id("C"), leftNeighbour: nil))
        #expect(PendingReturn.make(for: item(3, "C"), in: layout)
                == PendingReturn(section: .hidden, rightNeighbour: nil, leftNeighbour: id("B")))
    }

    @Test func neighboursWithoutAUniqueIdentityAreNotRecorded() throws {
        // The left neighbour has no identity; the right one shares its identity with another item.
        let layout: MenuBarLayout = [.hidden: [item(1, nil), item(2, "B"), item(3, "Twin"), item(4, "Twin")]]
        #expect(PendingReturn.make(for: item(2, "B"), in: layout) == PendingReturn(section: .hidden))
    }

    @Test func itemsOutsideTheLayoutHaveNoSlot() {
        #expect(PendingReturn.make(for: item(9, "Z"), in: [.hidden: [item(1, "A")]]) == nil)
    }

    // MARK: - Moving back

    /// Next launch: the item (new window 30) sits right of the Frost icon; its neighbours have new windows too.
    func relaunched(hidden: [MenuBarItem], alwaysHidden: [MenuBarItem] = []) -> MenuBarLayout {
        [.alwaysHidden: alwaysHidden, .hidden: hidden, .visible: [item(30, "C")]]
    }

    @Test func goesLeftOfItsRightNeighbourFirst() {
        let pending = PendingReturn(section: .hidden, rightNeighbour: id("D"), leftNeighbour: id("B"))
        let layout = relaunched(hidden: [item(20, "B"), item(21, "X"), item(22, "D")])
        #expect(pending.destination(for: 30, in: layout, controls: controls) == .leftOf(22))
    }

    @Test func fallsBackToTheLeftNeighbourThenTheSectionEdge() {
        let pending = PendingReturn(section: .hidden, rightNeighbour: id("D"), leftNeighbour: id("B"))
        // D's app isn't running.
        #expect(pending.destination(for: 30, in: relaunched(hidden: [item(20, "B")]), controls: controls)
                == .rightOf(20))
        // Neither is running.
        #expect(pending.destination(for: 30, in: relaunched(hidden: [item(21, "X")]), controls: controls)
                == .leftOf(101))
        #expect(PendingReturn(section: .alwaysHidden).destination(for: 30, in: relaunched(hidden: []),
                                                                   controls: controls) == .leftOf(102))
    }

    @Test func skipsANeighbourNowInAnotherSection() {
        let pending = PendingReturn(section: .hidden, rightNeighbour: id("D"), leftNeighbour: id("B"))
        // The user moved D to Always Hidden meanwhile: anchoring next to it would put C there too.
        let layout = relaunched(hidden: [item(20, "B")], alwaysHidden: [item(22, "D")])
        #expect(pending.destination(for: 30, in: layout, controls: controls) == .rightOf(20))
    }

    @Test func skipsANeighbourWhoseIdentityIsNowShared() {
        let pending = PendingReturn(section: .hidden, rightNeighbour: id("D"), leftNeighbour: id("B"))
        let layout = relaunched(hidden: [item(20, "B"), item(22, "D"), item(23, "D")])
        #expect(pending.destination(for: 30, in: layout, controls: controls) == .rightOf(20))
    }

    @Test func neverAnchorsToTheItemItself() {
        // A broken record naming the item as its own neighbour.
        let pending = PendingReturn(section: .hidden, rightNeighbour: id("C"))
        let layout: MenuBarLayout = [.hidden: [item(20, "B"), item(30, "C")]]
        #expect(pending.destination(for: 30, in: layout, controls: controls) == .leftOf(101))
    }

    // MARK: - Persistence

    /// Exactly what 0.3.2 stored under `pendingItemReturns.v1` (`SectionKeeper.encode`: `{bundleID, key, section}`).
    let stored032 = """
        [{"bundleID":"com.example.app","key":"desc:C","section":"hidden"},\
        {"bundleID":"com.example.other","key":"desc:Z","section":"alwaysHidden"}]
        """

    @Test func readsTheFormat032Wrote() throws {
        let decoded = try PendingReturn.decode(Data(stored032.utf8))
        #expect(decoded == [id("C"): PendingReturn(section: .hidden),
                            id("Z", bundleID: "com.example.other"): PendingReturn(section: .alwaysHidden)])
    }

    @Test func entriesWithoutNeighboursAreStoredAs032StoredThem() throws {
        let decoded = try PendingReturn.decode(Data(stored032.utf8))
        // The same JSON objects (JSONEncoder doesn't promise a key order).
        let written = try JSONSerialization.jsonObject(with: try PendingReturn.encode(decoded)) as? NSArray
        #expect(written == (try JSONSerialization.jsonObject(with: Data(stored032.utf8)) as? NSArray))
    }

    @Test func neighboursSurviveARoundTrip() throws {
        let returns = [id("C"): PendingReturn(section: .hidden, rightNeighbour: id("D"), leftNeighbour: id("B")),
                       id("E"): PendingReturn(section: .alwaysHidden, leftNeighbour: id("A"))]
        #expect(try PendingReturn.decode(try PendingReturn.encode(returns)) == returns)
    }

    /// 0.3.2's entry type, copied from its `SectionKeeper.Entry`: a downgrade still reads the sections.
    private struct Entry032: Codable, Equatable {
        var bundleID: String
        var key: String
        var section: MenuBarSection
    }

    @Test func aDowngradeTo032StillReadsTheSections() throws {
        let returns = [id("C"): PendingReturn(section: .hidden, rightNeighbour: id("D"), leftNeighbour: id("B"))]
        let entries = try JSONDecoder().decode([Entry032].self, from: try PendingReturn.encode(returns))
        #expect(entries == [Entry032(bundleID: "com.example.app", key: "desc:C", section: .hidden)])
    }
}
