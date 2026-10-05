import Testing
@testable import FrostCore

@Suite struct ItemIdentityKeyTests {
    typealias A = AXItemAttributes

    @Test func uniqueIdentifiersWin() {
        let keys = ItemIdentityKey.keys(for: [A(identifier: "com.apple.menuextra.clock", description: "Clock"),
                                              A(identifier: "com.apple.menuextra.controlcenter")])
        #expect(keys == ["id:com.apple.menuextra.clock", "id:com.apple.menuextra.controlcenter"])
    }

    @Test func descriptionsIdentifyItemsWithoutIdentifier() {
        let keys = ItemIdentityKey.keys(for: [A(description: "Weather"), A(description: "  Timer \n")])
        #expect(keys == ["desc:Weather", "desc:Timer"])
    }

    @Test func helpIsUsedWhenThereIsNoDescription() {
        #expect(ItemIdentityKey.keys(for: [A(description: "", help: "Sync status")]) == ["help:Sync status"])
    }

    @Test func itemsWithoutAttributesUseTheirIndex() {
        // Zero-size children count too: the index is the position in the app's AX children (creation order).
        let keys = ItemIdentityKey.keys(for: [A(description: "Menu"), A(), A(description: " ")])
        #expect(keys == ["desc:Menu", "idx:1", "idx:2"])
    }

    @Test func sharedDescriptionsAreNumberedInAXOrder() {
        let keys = ItemIdentityKey.keys(for: [A(description: "Status"), A(description: "Other"),
                                              A(description: "Status")])
        #expect(keys == ["desc:Status#0", "desc:Other", "desc:Status#1"])
    }

    @Test func suffixLikeLiteralDescriptionsNeverCollideWithNumberedDuplicates() {
        let keys = ItemIdentityKey.keys(for: [A(description: "Status"), A(description: "Status"),
                                              A(description: "Status#0"), A(help: "Sync#1"), A(description: ##"a\#0"##)])
        #expect(keys == ["desc:Status#0", "desc:Status#1", ##"desc:Status\#0"##, ##"help:Sync\#1"##, ##"desc:a\\\#0"##])
        #expect(Set(keys).count == keys.count)
    }

    @Test func literalSuffixesAreNumberedToo() {
        let keys = ItemIdentityKey.keys(for: [A(description: "Status#0"), A(description: "Status#0"),
                                              A(description: "Status")])
        #expect(keys == [##"desc:Status\#0#0"##, ##"desc:Status\#0#1"##, "desc:Status"])
    }

    @Test func theEarlierUnescapedEncodingIsRecoverable() {
        #expect(ItemIdentityKey.unescapedEncoding(of: ##"desc:Status\#0"##) == "desc:Status#0")
        #expect(ItemIdentityKey.unescapedEncoding(of: ##"help:C:\\x"##) == ##"help:C:\x"##)
        #expect(ItemIdentityKey.unescapedEncoding(of: "desc:Status#0") == nil)
        #expect(ItemIdentityKey.unescapedEncoding(of: "id:a\\#b") == nil)
    }

    @Test func duplicatedIdentifiersFallBackToDescriptions() {
        let keys = ItemIdentityKey.keys(for: [A(identifier: "item", description: "A"),
                                              A(identifier: "item", description: "B")])
        #expect(keys == ["desc:A", "desc:B"])
    }

    @Test func keysDoNotDependOnPositionInTheMenuBar() {
        // The same app read twice, before and after the user moved its items: AX order is creation order, so the keys
        // are the same (positions aren't an input at all).
        let children = [A(description: "One"), A(), A(description: "Two")]
        #expect(ItemIdentityKey.keys(for: children) == ItemIdentityKey.keys(for: children))
    }

    @Test func keysDoNotUseTheTitle() {
        // Text items' AX titles are what they show (a timer, a percentage) and change all the time; they aren't
        // `AXItemAttributes` at all, so an item described only by its text falls back to its index.
        #expect(ItemIdentityKey.keys(for: [A()]) == ["idx:0"])
    }

    @Test func emptyAppHasNoKeys() {
        #expect(ItemIdentityKey.keys(for: []).isEmpty)
    }
}
