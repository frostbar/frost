import AppKit
import FrostCore
import SwiftUI

// Menu bar item appearance shared by the layout editor and the Frost Bar: name, app icon cache, glyph view.

extension MenuBarItem {
    /// Tooltip / accessibility name: the AX description for system items (e.g. "Wi-Fi"), the app name otherwise.
    @MainActor var displayName: String {
        let systemOwners: Set<String> = ["com.apple.controlcenter", "com.apple.systemuiserver"]
        let description = axDescription.flatMap { $0.isEmpty ? nil : $0 }
        if let bundleID, systemOwners.contains(bundleID) {
            return description ?? windowTitle
        }
        let appName = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
        return appName ?? description ?? windowTitle
    }
}

/// App icons cached by bundle ID, shown for items without a capture (hidden by the notch or not captured yet).
@MainActor
final class AppIconCache {
    static let shared = AppIconCache()
    private var icons: [String: NSImage] = [:]

    func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = icons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }
}

/// A menu bar item's glyph: template image (tinted with the foreground color) -> capture (shown at the item's point
/// size, 2x pixels) -> app icon -> placeholder symbol.
/// Captures taller than the container (39 pt menu bar) have transparent margins that the container clips.
struct ItemGlyph: View {
    let item: MenuBarItem
    let image: CGImage?
    /// Template image of a monochrome glyph (`GlyphMask`): when present it is tinted with the foreground color
    /// (`.primary`) instead of showing the raw capture.
    var template: CGImage?
    let appIcon: NSImage?
    var appIconSize: CGFloat = 20
    /// Capture size in points; nil uses the item's frame.
    var imageSize: CGSize?

    private var size: CGSize { imageSize ?? item.frame.size }

    var body: some View {
        if let template {
            Image(decorative: template, scale: 1)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .foregroundStyle(.primary)
                .frame(width: size.width, height: size.height)
        } else if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
        } else if let appIcon {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: appIconSize, height: appIconSize)
        } else {
            Image(systemName: "questionmark.square.dashed")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
    }
}

extension GlyphTone {
    /// Glyph plate: dark plate for white glyphs, light plate for black glyphs (otherwise they vanish on a background of
    /// the opposite brightness).
    var plateColor: Color {
        switch self {
        case .light: Color.black.opacity(0.55)
        case .dark: Color.white.opacity(0.7)
        }
    }
}
