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
        // Numbers in the texts are normalized (`<n>`); the escaping still keeps them apart from occurrence suffixes.
        #expect(keys == ["desc:Status#0", "desc:Status#1", ##"desc:Status\#<n>"##, ##"help:Sync\#<n>"##,
                         ##"desc:a\\\#<n>"##])
        #expect(Set(keys).count == keys.count)
    }

    @Test func literalSuffixesAreNumberedToo() {
        let keys = ItemIdentityKey.keys(for: [A(description: "Status#0"), A(description: "Status#0"),
                                              A(description: "Status")])
        #expect(keys == [##"desc:Status\#<n>#0"##, ##"desc:Status\#<n>#1"##, "desc:Status"])
    }

    @Test func theEarlierUnescapedEncodingIsRecoverable() {
        #expect(ItemIdentityKey.unescapedEncoding(of: ##"desc:Status\#0"##) == "desc:Status#0")
        #expect(ItemIdentityKey.unescapedEncoding(of: ##"help:C:\\x"##) == ##"help:C:\x"##)
        #expect(ItemIdentityKey.unescapedEncoding(of: "desc:Status#0") == nil)
        #expect(ItemIdentityKey.unescapedEncoding(of: "id:a\\#b") == nil)
    }

    // MARK: Numbers in descriptions and help texts

    @Test func numbersInHelpTextsDoNotChangeTheKey() {
        // A fan-control-like item: no identifier or description, a tooltip with live readings.
        let first = ItemIdentityKey.keys(for: [A(help: "Left side - 4990 RPM\nRight side - 5012 RPM")])
        let second = ItemIdentityKey.keys(for: [A(help: "Left side - 5004 RPM\nRight side - 998 RPM")])
        #expect(first == ["help:Left side - <n> RPM\nRight side - <n> RPM"])
        #expect(first == second)
    }

    @Test func numbersInDescriptionsDoNotChangeTheKey() {
        #expect(ItemIdentityKey.keys(for: [A(description: "CPU 42%")]) == ["desc:CPU <n>%"])
        #expect(ItemIdentityKey.keys(for: [A(description: "CPU 7%")]) == ["desc:CPU <n>%"])
    }

    @Test(arguments: ["4,990 RPM", "4.9 RPM", "4\u{00A0}990 RPM", "4\u{202F}990 RPM", "4'990 RPM", "-3 RPM", "−3 RPM",
                      "12:30:05 RPM", "\u{0664}\u{0662} RPM"])
    func formattedNumbersCountAsOneNumber(_ text: String) {
        #expect(ItemIdentityKey.normalizingNumbers(text) == "<n> RPM")
    }

    @Test func numberBoundaries() {
        // A dash between words and a number is not a sign; a separator not followed by a digit ends the number.
        #expect(ItemIdentityKey.normalizingNumbers("Left - 5, right 6.") == "Left - <n>, right <n>.")
        #expect(ItemIdentityKey.normalizingNumbers("v2-3") == "v<n>-<n>")
        #expect(ItemIdentityKey.normalizingNumbers("No numbers") == "No numbers")
        #expect(ItemIdentityKey.normalizingNumbers("<n> 1") == "<n> <n>")
    }

    @Test func itemsDifferingOnlyInNumbersAreNumberedInAXOrder() {
        // Accepted collision: two items whose texts differ only in numbers share a base and are told apart by their
        // order among the app's extras (creation order), like any other shared text.
        let keys = ItemIdentityKey.keys(for: [A(description: "Fan 1"), A(description: "Other"),
                                              A(description: "Fan 2")])
        #expect(keys == ["desc:Fan <n>#0", "desc:Other", "desc:Fan <n>#1"])
    }

    @Test func identifierKeysKeepTheirNumbers() {
        #expect(ItemIdentityKey.keys(for: [A(identifier: "item-42", description: "7")]) == ["id:item-42"])
    }

    @Test func numberedKeysAreTheKeysOfTheEncodingBeforeNumbersWereNormalized() {
        let children = [A(description: "Fan 1"), A(help: "Status#2"), A(identifier: "x", description: "3"),
                        A(description: "Plain"), A(description: "Fan 2")]
        #expect(ItemIdentityKey.numberedKeys(for: children)
                == ["desc:Fan 1", ##"help:Status\#2"##, "id:x", "desc:Plain", "desc:Fan 2"])
    }

    @Test func numberNormalizedEncodingOfAStoredKeyKeepsItsOccurrenceSuffix() {
        #expect(ItemIdentityKey.numberNormalizedEncoding(of: "help:Left 4990 RPM") == "help:Left <n> RPM")
        #expect(ItemIdentityKey.numberNormalizedEncoding(of: "desc:CPU 40%#1") == "desc:CPU <n>%#1")
        #expect(ItemIdentityKey.numberNormalizedEncoding(of: ##"desc:Status\#0"##) == ##"desc:Status\#<n>"##)
        #expect(ItemIdentityKey.numberNormalizedEncoding(of: ##"desc:a\\1#2"##) == ##"desc:a\\<n>#2"##)
        #expect(ItemIdentityKey.numberNormalizedEncoding(of: "desc:Status#0") == nil)
        #expect(ItemIdentityKey.numberNormalizedEncoding(of: "desc:CPU <n>%") == nil)
        #expect(ItemIdentityKey.numberNormalizedEncoding(of: "id:item-42") == nil)
        #expect(ItemIdentityKey.numberNormalizedEncoding(of: "idx:3") == nil)
        #expect(ItemIdentityKey.numberNormalizedEncoding(of: "title:Item 3") == nil)
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
