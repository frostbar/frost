import Testing
import CoreGraphics
@testable import FrostCore

@Suite struct ItemFallbackAppearanceTests {
    func item(_ bundle: String?, width: CGFloat = 30, description: String? = nil, title: String? = nil,
              identifier: String? = nil) -> MenuBarItem {
        MenuBarItem(windowID: 1, frame: CGRect(x: 0, y: 0, width: width, height: 24), isOnScreen: true,
                    windowTitle: "", bundleID: bundle, pid: 1, axDescription: description ?? title, axTitle: title,
                    axIdentifier: identifier, identityKey: "k")
    }

    @Test func systemModulesGetSymbols() {
        #expect(ItemFallbackAppearance.symbol(for: item("com.apple.controlcenter",
                                                        identifier: "com.apple.menuextra.wifi")) == "wifi")
        #expect(ItemFallbackAppearance.symbol(for: item("com.apple.controlcenter",
                                                        identifier: "com.apple.menuextra.clock")) == "clock")
        #expect(ItemFallbackAppearance.symbol(for: item("com.apple.Spotlight")) == "magnifyingglass")
    }

    @Test func otherItemsUseTheAppIcon() {
        #expect(ItemFallbackAppearance.symbol(for: item("com.example.app", identifier: "custom")) == nil)
        #expect(ItemFallbackAppearance.symbol(for: item("com.apple.controlcenter",
                                                        identifier: "com.apple.menuextra.unknownthing")) == nil)
        #expect(ItemFallbackAppearance.symbol(for: item(nil)) == nil)
    }

    @Test func textItemsShowTheirText() {
        let text = item("com.example.app", width: 66, description: "Status", title: "42%")
        #expect(ItemFallbackAppearance.label(for: text, sharesIcon: false) == "42%")
        let wideIcon = item("com.example.app", width: 60, description: "Weather")
        #expect(ItemFallbackAppearance.label(for: wideIcon, sharesIcon: false) == "Weather")
    }

    @Test func labelsMarkItemsOfTheSameAppAsSharingTheirIcon() {
        func tile(_ id: CGWindowID, _ bundle: String, _ description: String, identifier: String? = nil) -> MenuBarItem {
            MenuBarItem(windowID: id, frame: CGRect(x: 0, y: 0, width: 30, height: 24), isOnScreen: true,
                        windowTitle: "", bundleID: bundle, pid: 1, axDescription: description,
                        axIdentifier: identifier, identityKey: "k\(id)")
        }
        let items = [tile(1, "com.a", "Sync"), tile(2, "com.a", "Status"), tile(3, "com.b", "Alone"),
                     tile(4, "com.apple.controlcenter", "Wi-Fi", identifier: "com.apple.menuextra.wifi"),
                     tile(5, "com.apple.controlcenter", "Mystery")]
        // com.a's two items look the same; com.b's single item and Control Center's symbol-bearing Wi-Fi don't need a
        // label; Control Center's item without a symbol is the only one using Control Center's icon.
        #expect(ItemFallbackAppearance.labels(for: items) == [1: "Sync", 2: "Status"])
    }

    @Test func narrowItemsShowOnlyTheIconUnlessItIsShared() {
        let icon = item("com.example.app", description: "Sync")
        #expect(ItemFallbackAppearance.label(for: icon, sharesIcon: false) == nil)
        #expect(ItemFallbackAppearance.label(for: icon, sharesIcon: true) == "Sync")
        // A system module has its own symbol: no label needed.
        let wifi = item("com.apple.controlcenter", description: "Wi-Fi", identifier: "com.apple.menuextra.wifi")
        #expect(ItemFallbackAppearance.label(for: wifi, sharesIcon: true) == nil)
        #expect(ItemFallbackAppearance.label(for: item("com.example.app"), sharesIcon: true) == nil)
    }

    @Test func aTextTileIsWideEnoughForItsWholeLabel() {
        // A 45 pt text item (a seconds counter): icon, spacing and padding take 26 pt, so a 33 pt text needs 59 pt.
        let wide = ItemFallbackAppearance.tileWidth(itemWidth: 45, labelTextWidth: 33)
        #expect(wide == 33 + ItemFallbackAppearance.besideOverhead)
        // Already roomy enough: unchanged.
        #expect(ItemFallbackAppearance.tileWidth(itemWidth: 120, labelTextWidth: 60) == 120)
        // An icon-sized item with a shared-icon label: the label goes below the icon.
        let narrow = ItemFallbackAppearance.tileWidth(itemWidth: 30, labelTextWidth: 41)
        #expect(narrow == 41 + ItemFallbackAppearance.belowOverhead)
        // No label: the item's own width.
        #expect(ItemFallbackAppearance.tileWidth(itemWidth: 30, labelTextWidth: nil) == 30)
    }

    @Test func theLabelFontFollowsTheLayout() {
        #expect(ItemFallbackAppearance.labelFontSize(itemWidth: ItemFallbackAppearance.minLabelWidth) == 11)
        #expect(ItemFallbackAppearance.labelFontSize(itemWidth: ItemFallbackAppearance.minLabelWidth - 1) == 8)
    }
}
