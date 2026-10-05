import CoreGraphics
import Foundation

/// How a tile looks when there is no image of its item (no Screen Recording, or not captured yet): the owning app's
/// icon, an SF Symbol for system items (whose owner, Control Center, has one icon for all of them), and a short label
/// where it helps tell items apart.
public enum ItemFallbackAppearance {
    /// An SF Symbol for a system item, chosen by its AX identifier (`com.apple.menuextra.<module>`) or, for items
    /// without one, by owner. nil: use the app's icon.
    public static func symbol(for item: MenuBarItem) -> String? {
        if let identifier = item.axIdentifier, identifier.hasPrefix(menuExtraPrefix) {
            let module = identifier.dropFirst(menuExtraPrefix.count).lowercased()
            if let match = moduleSymbols.first(where: { module.hasPrefix($0.module) }) { return match.symbol }
        }
        return item.bundleID.flatMap { ownerSymbols[$0] }
    }

    /// A short label for the tile, or nil when the icon alone says enough. A tile at least `minLabelWidth` wide (a
    /// text item) shows its text (AX title), else its description; a narrower one shows its description only when
    /// other tiles would show the same icon (`sharesIcon`: several items of one app without a symbol of their own).
    public static func label(for item: MenuBarItem, sharesIcon: Bool) -> String? {
        if item.frame.width >= minLabelWidth { return trimmed(item.axTitle) ?? trimmed(item.axDescription) }
        guard sharesIcon, symbol(for: item) == nil else { return nil }
        return trimmed(item.axDescription)
    }

    /// Labels of `items` (the tiles shown together), by window: an item shares its icon when another item of the same
    /// app without a symbol of its own is among them.
    public static func labels(for items: [MenuBarItem]) -> [CGWindowID: String] {
        let iconCounts = Dictionary(items.filter { symbol(for: $0) == nil }.map { ($0.bundleID ?? "", 1) },
                                    uniquingKeysWith: +)
        var result: [CGWindowID: String] = [:]
        for item in items {
            let shares = symbol(for: item) == nil && iconCounts[item.bundleID ?? "", default: 0] > 1
            if let label = label(for: item, sharesIcon: shares) { result[item.windowID] = label }
        }
        return result
    }

    /// Tiles narrower than this (an icon-sized item) show only the icon, unless several share it.
    public static let minLabelWidth: CGFloat = 44

    static let menuExtraPrefix = "com.apple.menuextra."

    /// Ordered: the first module name that the identifier's module starts with wins.
    static let moduleSymbols: [(module: String, symbol: String)] = [
        ("wifi", "wifi"),
        ("battery", "battery.75percent"),
        ("bluetooth", "dot.radiowaves.left.and.right"),
        ("sound", "speaker.wave.2.fill"),
        ("volume", "speaker.wave.2.fill"),
        ("focus", "moon.fill"),
        ("display", "sun.max.fill"),
        ("screenmirroring", "rectangle.on.rectangle"),
        ("airdrop", "airplayaudio"),
        ("nowplaying", "play.fill"),
        ("keyboardbrightness", "light.max"),
        ("textinput", "keyboard"),
        ("user", "person.crop.circle"),
        ("accessibility", "accessibility"),
        ("timemachine", "clock.arrow.trianglehead.counterclockwise.rotate.90"),
        ("vpn", "network.badge.shield.half.filled"),
        ("siri", "mic.fill"),
        ("clock", "clock"),
        ("controlcenter", "switch.2"),
    ]

    static let ownerSymbols: [String: String] = [
        "com.apple.Spotlight": "magnifyingglass",
        "com.apple.Siri": "mic.fill",
    ]

    static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
