import Testing
import CoreGraphics
import Foundation
@testable import FrostCore

/// Upgrades of what Frost remembers about icons (seen icons, remembered sections, window titles), driven through the
/// path that runs at launch: `ItemMemoryStore` loading a `UserDefaults` suite seeded exactly as an earlier release
/// stored it (keys and JSON copied from that release's code), then the steps `NewItemPlacer.evaluate` runs on every
/// decision (`migrateIdentities`, `decideNewItems`, `observeSections`). The individual helpers (`IdentityMigration`,
/// `SectionKeeper`, `NewItemPlacement`) have their own tests; these check that composed, they keep every section and
/// treat nothing as new, and that the next launch changes nothing.
@MainActor
@Suite struct ItemMemoryUpgradeTests {
    let suiteName = "ItemMemoryUpgradeTests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Everything stored in the suite (to check that a launch changed nothing).
    var stored: NSDictionary { NSDictionary(dictionary: defaults.persistentDomain(forName: suiteName) ?? [:]) }

    func seed(_ json: String, forKey key: String) {
        defaults.set(Data(json.utf8), forKey: key)
    }

    // MARK: - Items

    /// One app's items as the scanner builds them: identity keys from their AX descriptions (`ItemIdentityKey`), the
    /// numbered key only where it differs (`AXExtrasReader`).
    func items(_ bundleID: String, firstWindow: CGWindowID, descriptions: [String],
               titles: [String]? = nil) -> [MenuBarItem] {
        let attributes = descriptions.map { AXItemAttributes(description: $0) }
        let keys = ItemIdentityKey.keys(for: attributes)
        let numbered = ItemIdentityKey.numberedKeys(for: attributes)
        return descriptions.indices.map { index in
            item(firstWindow + CGWindowID(index), bundleID, key: keys[index],
                 numbered: numbered[index] == keys[index] ? nil : numbered[index], title: titles?[index] ?? "")
        }
    }

    func item(_ windowID: CGWindowID, _ bundleID: String, key: String, numbered: String? = nil,
              title: String = "", axIdentifier: String? = nil) -> MenuBarItem {
        MenuBarItem(windowID: windowID, frame: CGRect(x: CGFloat(windowID) * 30, y: 0, width: 29, height: 24),
                    isOnScreen: true, windowTitle: title, bundleID: bundleID, pid: 1, axDescription: nil,
                    axIdentifier: axIdentifier, identityKey: key, numberedIdentityKey: numbered)
    }

    func clock(_ windowID: CGWindowID, title: String = "") -> MenuBarItem {
        item(windowID, SystemItemRules.controlCenterBundleID, key: "id:" + SystemItemRules.clockIdentifier,
             title: title, axIdentifier: SystemItemRules.clockIdentifier)
    }

    func id(_ bundleID: String, _ key: String) -> ItemIdentity { ItemIdentity(bundleID: bundleID, key: key) }

    // MARK: - Launch

    /// One launch of Frost: a store loaded from the suite, and the windows handled so far in this run.
    @MainActor final class Run {
        let store: ItemMemoryStore
        var considered: Set<CGWindowID> = []

        init(defaults: UserDefaults) {
            store = ItemMemoryStore(defaults: defaults)
        }
    }

    struct Evaluation {
        var decision: NewItemPlacement.Decision
        var outcome: SectionKeeper.Outcome

        /// Nothing was treated as new, moved, seeded or recorded as the user's move.
        var changedNothing: Bool {
            decision.toMove.isEmpty && decision.learned.isEmpty && outcome.restores.isEmpty
                && outcome.userMoves.isEmpty && outcome.seeded.isEmpty
        }
    }

    /// One decision of `NewItemPlacer.evaluate` on a trusted, collapsed layout, with the same FrostCore calls in the
    /// same order (migrate, then new items, then the section memory skipping the items being placed).
    func evaluate(_ run: Run, _ layout: MenuBarLayout) -> Evaluation {
        let items = MenuBarSection.leftToRight.flatMap { layout[$0, default: []] }
        run.store.migrateIdentities(items)
        let decision = run.store.decideNewItems(layout: layout, items: items, considered: run.considered)
        run.considered = decision.considered
        let outcome = run.store.observeSections(layout: layout, items: items, obscured: [], movedByFrost: [],
                                                skipping: Set(decision.toMove.map(\.windowID)), restoreEnabled: true,
                                                canMove: true)
        return Evaluation(decision: decision, outcome: outcome)
    }

    /// Launches Frost on the suite and checks that it changes nothing at all, stored or decided.
    func expectRelaunchChangesNothing(_ layout: MenuBarLayout, sourceLocation: SourceLocation = #_sourceLocation) {
        let before = stored
        let run = Run(defaults: defaults)
        let evaluation = evaluate(run, layout)
        #expect(evaluation.changedNothing, sourceLocation: sourceLocation)
        #expect(stored == before, sourceLocation: sourceLocation)
    }

    func decodedSections() throws -> [ItemIdentity: MenuBarSection] {
        try SectionKeeper.decode(try #require(defaults.data(forKey: "itemSections.v2")))
    }

    func decodedKnown() throws -> Set<ItemIdentity> {
        try NewItemPlacement.decode(try #require(defaults.data(forKey: "knownItemIdentities.v2")))
    }

    // MARK: - From 0.3.0

    /// Protects the upgrade from 0.3.0, which keyed items by AX descriptions with live numbers in them: two fans of one
    /// app (now sharing a text, told apart by occurrence suffixes), a reading remembered under two values, a plain
    /// item, the clock, and two windows sharing one identity (an item re-created while its old window lingers).
    @Test func sectionsAndKnownItemsFrom030SurviveTheUpgrade() throws {
        defer { cleanUp() }
        // Stored by 0.3.0 (`NewItemPlacement.encode`, `SectionKeeper.encode`, `IdentityMigration.encodeTitles`).
        seed("""
            [{"bundleID":"com.apple.controlcenter","key":"id:com.apple.menuextra.clock"},\
            {"bundleID":"com.example.CPU","key":"desc:CPU 37%"},{"bundleID":"com.example.CPU","key":"desc:CPU 41%"},\
            {"bundleID":"com.example.Fans","key":"desc:Fan 1"},{"bundleID":"com.example.Fans","key":"desc:Fan 2"},\
            {"bundleID":"com.example.Twin","key":"desc:Twin"},{"bundleID":"com.example.Weather","key":"desc:Weather"}]
            """, forKey: "knownItemIdentities.v2")
        seed("""
            [{"bundleID":"com.example.CPU","key":"desc:CPU 37%","section":"hidden"},\
            {"bundleID":"com.example.CPU","key":"desc:CPU 41%","section":"hidden"},\
            {"bundleID":"com.example.Fans","key":"desc:Fan 1","section":"alwaysHidden"},\
            {"bundleID":"com.example.Fans","key":"desc:Fan 2","section":"hidden"},\
            {"bundleID":"com.example.Twin","key":"desc:Twin","section":"alwaysHidden"},\
            {"bundleID":"com.example.Weather","key":"desc:Weather","section":"visible"}]
            """, forKey: "itemSections.v2")
        seed("""
            [{"bundleID":"com.example.CPU","key":"desc:CPU 37%","title":"CPUItem"},\
            {"bundleID":"com.example.Fans","key":"desc:Fan 1","title":"FanItem1"},\
            {"bundleID":"com.example.Fans","key":"desc:Fan 2","title":"FanItem2"}]
            """, forKey: "itemTitles.v1")

        // Accessibility only (no window titles). The icons are where the user left them.
        let fans = items("com.example.Fans", firstWindow: 10, descriptions: ["Fan 1", "Fan 2"])
        let cpu = items("com.example.CPU", firstWindow: 20, descriptions: ["CPU 52%"])
        let weather = items("com.example.Weather", firstWindow: 30, descriptions: ["Weather"])
        let twins = [item(40, "com.example.Twin", key: "desc:Twin"), item(41, "com.example.Twin", key: "desc:Twin")]
        let layout: MenuBarLayout = [.alwaysHidden: [fans[0]] + twins, .hidden: [fans[1]] + cpu,
                                     .visible: weather + [clock(50)]]

        let fan0 = id("com.example.Fans", "desc:Fan <n>#0"), fan1 = id("com.example.Fans", "desc:Fan <n>#1")
        let reading = id("com.example.CPU", "desc:CPU <n>%")
        let twin = id("com.example.Twin", "desc:Twin"), plain = id("com.example.Weather", "desc:Weather")
        let expectedSections: [ItemIdentity: MenuBarSection] = [fan0: .alwaysHidden, fan1: .hidden, reading: .hidden,
                                                                twin: .alwaysHidden, plain: .visible]
        let expectedKnown: Set = [fan0, fan1, reading, twin, plain,
                                  id("com.apple.controlcenter", "id:com.apple.menuextra.clock")]

        let run = Run(defaults: defaults)
        let first = evaluate(run, layout)
        #expect(first.changedNothing)
        #expect(first.outcome.ambiguous == [twin])
        #expect(run.store.keeper.memory == expectedSections)
        #expect(run.store.known == expectedKnown)
        #expect(try decodedSections() == expectedSections)
        #expect(try decodedKnown() == expectedKnown)
        #expect(run.store.titles == [fan0: "FanItem1", fan1: "FanItem2", reading: "CPUItem"])

        // The rest of this run and the next launches change nothing.
        let before = stored
        #expect(evaluate(run, layout).changedNothing)
        #expect(stored == before)
        expectRelaunchChangesNothing(layout)
        expectRelaunchChangesNothing(layout)
    }

    /// Protects the upgrade from 0.3.0 when an app re-added an icon somewhere else while Frost was not running (the
    /// reason the section memory exists): the migrated memory, not the icon's current spot, decides, so it is moved
    /// back rather than seeded where it landed.
    @Test func aDisplacedIconFrom030GoesBackToItsMigratedSection() throws {
        defer { cleanUp() }
        seed("""
            [{"bundleID":"com.example.Fans","key":"desc:Fan 1"},{"bundleID":"com.example.Fans","key":"desc:Fan 2"}]
            """, forKey: "knownItemIdentities.v2")
        seed("""
            [{"bundleID":"com.example.Fans","key":"desc:Fan 1","section":"visible"},\
            {"bundleID":"com.example.Fans","key":"desc:Fan 2","section":"hidden"}]
            """, forKey: "itemSections.v2")
        let fans = items("com.example.Fans", firstWindow: 10, descriptions: ["Fan 1", "Fan 2"])
        // The first fan was re-added at the far left (Always Hidden).
        let layout: MenuBarLayout = [.alwaysHidden: [fans[0]], .hidden: [fans[1]], .visible: []]

        let run = Run(defaults: defaults)
        let evaluation = evaluate(run, layout)
        #expect(evaluation.decision.toMove.isEmpty)
        #expect(evaluation.outcome.seeded.isEmpty)
        #expect(evaluation.outcome.restores.map(\.item.windowID) == [fans[0].windowID])
        #expect(evaluation.outcome.restores.map(\.to) == [.visible])
        #expect(try decodedSections() == [id("com.example.Fans", "desc:Fan <n>#0"): .visible,
                                          id("com.example.Fans", "desc:Fan <n>#1"): .hidden])
    }

    // MARK: - From 0.2.x

    /// Stored by 0.2.x (keyed by window title): `knownItemIdentities` (`{bundleID, title}`) and `itemSections.v1`
    /// (`{bundleID, title, section}`). One app with two icons, one with a single icon, and the clock.
    func seed02() {
        seed("""
            [{"bundleID":"com.apple.controlcenter","title":"Clock"},{"bundleID":"com.example.Multi","title":"MultiA"},\
            {"bundleID":"com.example.Multi","title":"MultiB"},{"bundleID":"com.example.Weather","title":"WeatherItem"}]
            """, forKey: "knownItemIdentities")
        seed("""
            [{"bundleID":"com.example.Multi","title":"MultiA","section":"alwaysHidden"},\
            {"bundleID":"com.example.Multi","title":"MultiB","section":"hidden"},\
            {"bundleID":"com.example.Weather","title":"WeatherItem","section":"visible"}]
            """, forKey: "itemSections.v1")
    }

    /// The 0.2.x icons as the current release scans them; `titled`: with Screen Recording (window titles readable).
    func layout02(titled: Bool) -> MenuBarLayout {
        let multi = items("com.example.Multi", firstWindow: 10, descriptions: ["Alpha", "Beta"],
                          titles: titled ? ["MultiA", "MultiB"] : nil)
        let weather = items("com.example.Weather", firstWindow: 20, descriptions: ["Weather"],
                            titles: titled ? ["WeatherItem"] : nil)
        return [.alwaysHidden: [multi[0]], .hidden: [multi[1]],
                .visible: weather + [clock(30, title: titled ? "Clock" : "")]]
    }

    var expectedSections02: [ItemIdentity: MenuBarSection] {
        [id("com.example.Multi", "desc:Alpha"): .alwaysHidden, id("com.example.Multi", "desc:Beta"): .hidden,
         id("com.example.Weather", "desc:Weather"): .visible]
    }

    var expectedKnown02: Set<ItemIdentity> {
        [id("com.example.Multi", "desc:Alpha"), id("com.example.Multi", "desc:Beta"),
         id("com.example.Weather", "desc:Weather"), id("com.apple.controlcenter", "id:com.apple.menuextra.clock")]
    }

    /// Protects the upgrade from 0.2.x with Screen Recording: every title-keyed entry maps by title on the first
    /// launch, the icon the user keeps in Always Hidden stays there, and the 0.2.x keys are left in place.
    @Test func sectionsAndKnownItemsFrom02MapByTitle() throws {
        defer { cleanUp() }
        seed02()
        let layout = layout02(titled: true)

        let run = Run(defaults: defaults)
        let first = evaluate(run, layout)
        #expect(first.changedNothing)
        #expect(run.store.keeper.memory == expectedSections02)
        #expect(try decodedSections() == expectedSections02)
        #expect(try decodedKnown() == expectedKnown02)
        #expect(defaults.data(forKey: "itemSections.v1") != nil)
        #expect(defaults.data(forKey: "knownItemIdentities") != nil)

        expectRelaunchChangesNothing(layout)
        expectRelaunchChangesNothing(layout)
    }

    /// Protects the upgrade from 0.2.x with Accessibility only: the two icons of one app can't be told apart without
    /// titles, so they are neither treated as new nor seeded where they are (which would win over the user's choice
    /// later); the sole icon of an app maps without a title. Once Screen Recording is granted, the rest maps.
    @Test func ambiguousEntriesFrom02WaitForTitlesWithoutBeingTreatedAsNew() throws {
        defer { cleanUp() }
        seed02()
        let untitled = layout02(titled: false)
        let legacyA = IdentityMigration.legacy(bundleID: "com.example.Multi", title: "MultiA")
        let legacyB = IdentityMigration.legacy(bundleID: "com.example.Multi", title: "MultiB")

        let run = Run(defaults: defaults)
        let first = evaluate(run, untitled)
        #expect(first.changedNothing)
        #expect(run.store.keeper.memory == [legacyA: .alwaysHidden, legacyB: .hidden,
                                            id("com.example.Weather", "desc:Weather"): .visible])
        #expect(try decodedKnown() == [legacyA, legacyB, id("com.example.Weather", "desc:Weather"),
                                       id("com.apple.controlcenter", "id:com.apple.menuextra.clock")])
        expectRelaunchChangesNothing(untitled)

        // Screen Recording granted, Frost relaunched: the titles are readable and the remaining entries map.
        let titled = layout02(titled: true)
        let granted = Run(defaults: defaults)
        #expect(evaluate(granted, titled).changedNothing)
        #expect(granted.store.keeper.memory == expectedSections02)
        #expect(try decodedSections() == expectedSections02)
        #expect(try decodedKnown() == expectedKnown02)
        expectRelaunchChangesNothing(titled)
    }
}
