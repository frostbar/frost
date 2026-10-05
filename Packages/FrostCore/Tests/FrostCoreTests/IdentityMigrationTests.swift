import Testing
import CoreGraphics
import Foundation
@testable import FrostCore

@Suite struct IdentityMigrationTests {
    func item(_ windowID: CGWindowID, _ bundle: String?, key: String?, title: String = "") -> MenuBarItem {
        MenuBarItem(windowID: windowID, frame: CGRect(x: CGFloat(windowID) * 30, y: 0, width: 29, height: 24),
                    isOnScreen: true, windowTitle: title, bundleID: bundle, pid: 1, axDescription: nil,
                    identityKey: bundle == nil ? nil : key)
    }
    func id(_ bundle: String, _ key: String) -> ItemIdentity { ItemIdentity(bundleID: bundle, key: key) }
    func legacy(_ bundle: String, _ title: String) -> ItemIdentity {
        IdentityMigration.legacy(bundleID: bundle, title: title)
    }

    // MARK: Legacy (title-keyed) identities

    @Test func legacyIdentitiesMapByTitleWhenTitlesAreReadable() {
        let items = [item(1, "com.a", key: "desc:Weather", title: "Item-0"),
                     item(2, "com.a", key: "idx:1", title: "Item-1"),
                     item(3, "com.b", key: "id:x", title: "Main")]
        let stored: Set = [legacy("com.a", "Item-0"), legacy("com.a", "Item-1"), legacy("com.b", "Main")]
        let plan = IdentityMigration.plan(stored: stored, items: items)
        #expect(plan == [legacy("com.a", "Item-0"): id("com.a", "desc:Weather"),
                         legacy("com.a", "Item-1"): id("com.a", "idx:1"),
                         legacy("com.b", "Main"): id("com.b", "id:x")])
    }

    @Test func legacyIdentitiesOfMultiItemAppsWaitForTitles() {
        // No Screen Recording: titles are empty. Two items of one app can't be told apart by title, so nothing maps.
        let items = [item(1, "com.a", key: "desc:A"), item(2, "com.a", key: "desc:B")]
        let stored: Set = [legacy("com.a", "Item-0"), legacy("com.a", "Item-1")]
        #expect(IdentityMigration.plan(stored: stored, items: items).isEmpty)
    }

    @Test func soleItemOfAnAppTakesOverItsSoleLegacyIdentityWithoutTitles() {
        let items = [item(1, "com.a", key: "idx:0"), item(2, "com.b", key: "desc:B")]
        let stored: Set = [legacy("com.a", "Item-0"), legacy("com.b", "X"), legacy("com.b", "Y")]
        // com.a: one item, one remembered identity → mapped. com.b: one item but two remembered identities →
        // unclear.
        #expect(IdentityMigration.plan(stored: stored, items: items)
                == [legacy("com.a", "Item-0"): id("com.a", "idx:0")])
    }

    @Test func alreadyRememberedIdentitiesAreLeftAlone() {
        let items = [item(1, "com.a", key: "desc:A", title: "Item-0")]
        let stored: Set = [id("com.a", "desc:A"), legacy("com.a", "Item-0")]
        #expect(IdentityMigration.plan(stored: stored, items: items).isEmpty)
    }

    @Test func sharedIdentitiesAndTitlesAreNotMapped() {
        // A re-created item whose old window lingers: two windows with one identity.
        let items = [item(1, "com.a", key: "desc:A", title: "Item-0"), item(2, "com.a", key: "desc:A", title: "Item-0")]
        #expect(IdentityMigration.plan(stored: [legacy("com.a", "Item-0")], items: items).isEmpty)
        // Two items sharing a title can't claim a legacy identity by it.
        let twins = [item(1, "com.a", key: "desc:A", title: "Same"), item(2, "com.a", key: "desc:B", title: "Same")]
        #expect(IdentityMigration.plan(stored: [legacy("com.a", "Same")], items: twins).isEmpty)
    }

    @Test func unresolvedItemsDoNotTakeAnything() {
        let items = [item(1, nil, key: nil, title: "Item-0")]
        #expect(IdentityMigration.plan(stored: [legacy("com.a", "Item-0")], items: items).isEmpty)
    }

    @Test func eachRememberedIdentityMapsOnce() {
        // Two items of one app, one remembered identity: the title decides; without titles, nothing.
        let stored: Set = [legacy("com.a", "Item-0")]
        let titled = [item(1, "com.a", key: "desc:A", title: "Item-1"),
                      item(2, "com.a", key: "desc:B", title: "Item-0")]
        #expect(IdentityMigration.plan(stored: stored, items: titled)
                == [legacy("com.a", "Item-0"): id("com.a", "desc:B")])
        let untitled = [item(1, "com.a", key: "desc:A"), item(2, "com.a", key: "desc:B")]
        #expect(IdentityMigration.plan(stored: stored, items: untitled).isEmpty)
    }

    // MARK: Changed keys

    @Test func aChangedDescriptionFollowsTheTitleLastSeenWithIt() {
        // The app's item was remembered as "desc:Sunny"; now it describes itself as "desc:Rain". Its window title (the
        // autosave name) still matches the one recorded with the old identity.
        let items = [item(1, "com.a", key: "desc:Rain", title: "weather"), item(2, "com.a", key: "desc:Other",
                                                                            title: "other")]
        let stored: Set = [id("com.a", "desc:Sunny"), id("com.a", "desc:Other")]
        let titles = [id("com.a", "desc:Sunny"): "weather", id("com.a", "desc:Other"): "other"]
        #expect(IdentityMigration.plan(stored: stored, titles: titles, items: items)
                == [id("com.a", "desc:Sunny"): id("com.a", "desc:Rain")])
    }

    @Test func aChangedDescriptionOfASoleItemFollowsWithoutTitles() {
        let items = [item(1, "com.a", key: "desc:Rain")]
        #expect(IdentityMigration.plan(stored: [id("com.a", "desc:Sunny")], items: items)
                == [id("com.a", "desc:Sunny"): id("com.a", "desc:Rain")])
    }

    // MARK: Applying

    @Test func applyMovesValuesAndKeepsExistingEntries() {
        let plan = [legacy("com.a", "T"): id("com.a", "desc:A"), legacy("com.b", "U"): id("com.b", "desc:B")]
        let values: [ItemIdentity: MenuBarSection] = [legacy("com.a", "T"): .visible, legacy("com.b", "U"): .hidden,
                                                      id("com.b", "desc:B"): .alwaysHidden]
        #expect(IdentityMigration.apply(plan, to: values)
                == [id("com.a", "desc:A"): .visible, id("com.b", "desc:B"): .alwaysHidden])
        #expect(IdentityMigration.apply(plan, to: Set(values.keys))
                == [id("com.a", "desc:A"), id("com.b", "desc:B")])
    }

    @Test func itemsOfAppsWithUnmappedLegacyIdentitiesArePresumedKnown() {
        let known: Set = [legacy("com.a", "Item-0"), legacy("com.a", "Item-1"), id("com.c", "desc:C")]
        let items = [item(1, "com.a", key: "desc:A"), item(2, "com.b", key: "desc:B"),
                     item(3, "com.a", key: "desc:Z", title: "Item-9")]
        // com.a's untitled item may be one of its legacy identities; com.b has none; a titled item can be decided.
        #expect(IdentityMigration.presumedKnown(known: known, items: items) == [id("com.a", "desc:A")])
        #expect(IdentityMigration.presumedKnown(known: [id("com.a", "desc:Q")], items: items).isEmpty)
    }

    // MARK: Titles

    @Test func titlesAreRecordedForUniqueIdentities() throws {
        let items = [item(1, "com.a", key: "desc:A", title: "a"), item(2, "com.b", key: "desc:B"),
                     item(3, "com.c", key: "desc:C", title: "c1"), item(4, "com.c", key: "desc:C", title: "c2")]
        let titles = try #require(IdentityMigration.updatedTitles([:], items: items))
        #expect(titles == [id("com.a", "desc:A"): "a"])
        #expect(IdentityMigration.updatedTitles(titles, items: items) == nil)
    }

    @Test func titlesRoundTrip() throws {
        let titles = [id("com.b", "desc:B"): "b", id("com.a", "idx:0"): "a"]
        let data = try IdentityMigration.encodeTitles(titles)
        #expect(try IdentityMigration.decodeTitles(data) == titles)
        let entries = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: String]])
        #expect(entries.map { $0["bundleID"] } == ["com.a", "com.b"])
    }

    // MARK: Known identities persistence

    @Test func knownIdentitiesVersion1IsReadAsLegacy() throws {
        let v1 = Data(#"[{"bundleID":"com.a","title":"Item-0"}]"#.utf8)
        #expect(try NewItemPlacement.decodeLegacy(v1) == [legacy("com.a", "Item-0")])
        let v2 = try NewItemPlacement.encode([id("com.b", "desc:B"), id("com.a", "idx:0")])
        #expect(try NewItemPlacement.decode(v2) == [id("com.b", "desc:B"), id("com.a", "idx:0")])
        let entries = try #require(try JSONSerialization.jsonObject(with: v2) as? [[String: String]])
        #expect(entries == [["bundleID": "com.a", "key": "idx:0"], ["bundleID": "com.b", "key": "desc:B"]])
    }
}
