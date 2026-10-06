import Testing
import CoreGraphics
import CryptoKit
import Foundation
@testable import FrostCore

/// Upgrades of the icon image disk cache, driven through the path that runs at launch:
/// `ItemImageCapturer.preloadCached` (started when Frost launches) followed by `missing` (the Frost Bar's first open),
/// or `missing` / `loadCached` alone (the Frost Bar opened before the preload ran). A real `ItemImageDiskCache`
/// directory is seeded with files exactly as earlier releases wrote them, several items at once. Testing `migrate` and
/// `earlierKeys` separately missed the crash in 0.3.1, where composing them at launch moved an entry and then looked
/// for it again.
@MainActor
@Suite struct ItemImageCacheUpgradeTests {
    let root: URL
    let cache: ItemImageDiskCache
    let now = Date()

    init() {
        root = FileManager.default.temporaryDirectory
            .appending(path: "FrostCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        cache = ItemImageDiskCache(directory: root.appending(path: "items", directoryHint: .isDirectory))
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Earlier releases' files

    /// Metadata as 0.2.x wrote it: entries keyed by window title (identity keys didn't exist yet).
    struct MetadataV02: Encodable {
        var version = 1
        var bundleID: String
        var title: String
        var appearance: MenuBarAppearance
        var scale: Int
        var tone: GlyphTone
        var style: GlyphStyle
        var pixelWidth: Int
        var pixelHeight: Int
        var capturedAt: Date
        var lastSeen: Date
    }

    /// Metadata as 0.3.0 wrote it: entries keyed by the AX identity key, numbers in descriptions kept as they were.
    struct MetadataV030: Encodable {
        var version = 1
        var bundleID: String
        var key: String
        var appearance: MenuBarAppearance
        var scale: Int
        var tone: GlyphTone
        var style: GlyphStyle
        var pixelWidth: Int
        var pixelHeight: Int
        var capturedAt: Date
        var lastSeen: Date
    }

    /// The file stem both releases used: `<bundle ID>-<first 8 bytes of SHA-256(bundle ID, NUL, title or key) in
    /// hex>-<appearance>@<scale>x` (the test bundle IDs need no sanitizing). Computed here rather than with
    /// `ItemImageCacheKey.fileStem`, so a change to the current naming can't hide that old files are no longer found.
    static func stem(bundleID: String, discriminator: String, appearance: MenuBarAppearance, scale: Int) -> String {
        let digest = SHA256.hash(data: Data((bundleID + "\u{0}" + discriminator).utf8))
        let hash = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(bundleID)-\(hash)-\(appearance.rawValue)@\(scale)x"
    }

    /// Writes one entry (PNG, then metadata, encoded the way both releases encoded it) under `stem`.
    func write(_ image: CGImage, metadata: some Encodable, stem: String) throws {
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        let png = try #require(ItemImageDiskCache.pngData(image))
        try png.write(to: cache.directory.appending(path: stem + ".png"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(metadata).write(to: cache.directory.appending(path: stem + ".json"))
    }

    /// The cache's file names (in-flight temporary files of atomic writes left out).
    func files() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path).filter {
            !$0.hasPrefix(".") && ($0.hasSuffix(".png") || $0.hasSuffix(".json"))
        })
    }

    /// An opaque glyph of `width` × `height` pixels (any visible pixel will do).
    static func glyph(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        return context.makeImage()!
    }

    // MARK: - Items

    func item(_ windowID: CGWindowID, _ bundleID: String, key: String, numbered: String? = nil,
              title: String = "") -> MenuBarItem {
        MenuBarItem(windowID: windowID, frame: CGRect(x: CGFloat(windowID) * 30, y: 0, width: 22, height: 24),
                    isOnScreen: true, windowTitle: title, bundleID: bundleID, pid: 1, axDescription: nil,
                    identityKey: key, numberedIdentityKey: numbered)
    }

    enum LaunchPath: CaseIterable {
        /// `preloadCached` at launch, then the Frost Bar's first open (`missing`).
        case preloadThenOpen
        /// The Frost Bar opened before any preload (`missing`, which loads synchronously).
        case openOnly
    }

    /// One launch: a fresh capturer on the cache directory, through `path`. Returns it and what it still reports as
    /// missing (to capture with a menu bar expansion).
    func launch(_ path: LaunchPath, items: [MenuBarItem]) async -> (ItemImageCapturer, [CGWindowID]) {
        let capturer = ItemImageCapturer(diskCache: cache)
        if path == .preloadThenOpen { await capturer.preloadCached(items) }
        return (capturer, capturer.missing(items).map(\.windowID))
    }

    // MARK: - Upgrades

    /// Protects upgrades from 0.2.x (entries keyed by window title) and 0.3.0 (entries keyed by identity keys with
    /// live numbers in them) to the current release, for every item at once; 0.3.1 crashed at launch on exactly this.
    @Test(arguments: LaunchPath.allCases)
    func entriesOfEarlierReleasesLoadAndMoveToTheCurrentKeys(path: LaunchPath) async throws {
        defer { cleanUp() }
        let appearance = ItemImageCapturer.currentAppearance
        let scale = Int(ItemImageCapturer(diskCache: nil).menuBarScale)
        let width = 22 * scale, height = 24 * scale
        let earlier = now.addingTimeInterval(-10 * 24 * 3600)

        // Two fan readings of one app: since 0.3.1 their descriptions share a key and get occurrence suffixes; 0.3.0
        // keyed them with their numbers.
        let fans = [AXItemAttributes(description: "Fan 1"), AXItemAttributes(description: "Fan 2")]
        let fanKeys = ItemIdentityKey.keys(for: fans)
        let numberedFanKeys = ItemIdentityKey.numberedKeys(for: fans)
        #expect(fanKeys != numberedFanKeys)

        // Already stored under its current key (written by this release, e.g. on an earlier launch).
        let current = item(11, "com.example.Weather", key: "desc:Weather", title: "WeatherItem")
        // A 0.2.x entry under the window title (readable with Screen Recording, which captures need anyway).
        let titled = item(12, "com.example.Clipboard", key: "desc:Clipboard", title: "ClipboardItem")
        // 0.3.0 entries under the numbered keys; the second fan also has a title with no entry (first earlier key
        // misses, the second one hits).
        let fan1 = item(13, "com.example.Fans", key: fanKeys[0], numbered: numberedFanKeys[0])
        let fan2 = item(14, "com.example.Fans", key: fanKeys[1], numbered: numberedFanKeys[1], title: "FanItem2")
        // Nothing stored anywhere.
        let uncached = item(15, "com.example.New", key: "desc:New", title: "NewItem")
        let items = [current, titled, fan1, fan2, uncached]

        try cache.save(Self.glyph(width: width, height: height), tone: .light, style: .colored(plate: nil),
                       for: ItemImageCacheKey(identity: try #require(current.identity), appearance: appearance,
                                              scale: scale),
                       now: now.addingTimeInterval(-3600))
        let titleStem = Self.stem(bundleID: "com.example.Clipboard", discriminator: "ClipboardItem",
                                  appearance: appearance, scale: scale)
        try write(Self.glyph(width: width, height: height),
                  metadata: MetadataV02(bundleID: "com.example.Clipboard", title: "ClipboardItem",
                                        appearance: appearance, scale: scale, tone: .dark, style: .monochrome(.dark),
                                        pixelWidth: width, pixelHeight: height, capturedAt: earlier, lastSeen: earlier),
                  stem: titleStem)
        var numberedStems: [String] = []
        for (numbered, style) in zip(numberedFanKeys, [GlyphStyle.monochrome(.light), .colored(plate: .light)]) {
            let stem = Self.stem(bundleID: "com.example.Fans", discriminator: numbered, appearance: appearance,
                                 scale: scale)
            numberedStems.append(stem)
            try write(Self.glyph(width: width, height: height),
                      metadata: MetadataV030(bundleID: "com.example.Fans", key: numbered, appearance: appearance,
                                             scale: scale, tone: .light, style: style, pixelWidth: width,
                                             pixelHeight: height, capturedAt: earlier, lastSeen: earlier),
                      stem: stem)
        }

        // First launch after the upgrade: no crash, every cached item gets its own image, only the uncached one is
        // left to capture.
        let (capturer, missing) = await launch(path, items: items)
        #expect(missing == [uncached.windowID])
        #expect(capturer.styles == [current.windowID: .colored(plate: nil), titled.windowID: .monochrome(.dark),
                                    fan1.windowID: .monochrome(.light), fan2.windowID: .colored(plate: .light)])
        for cached in [current, titled, fan1, fan2] {
            #expect(capturer.images[cached.windowID]?.height == height)
            #expect(capturer.sizes[cached.windowID] == CGSize(width: 22, height: 24))
        }
        #expect(capturer.images[uncached.windowID] == nil)

        // The entries now live under the current keys; the old files are gone.
        let currentKeys = try [current, titled, fan1, fan2].map {
            ItemImageCacheKey(identity: try #require($0.identity), appearance: appearance, scale: scale)
        }
        for key in currentKeys { #expect(cache.load(key) != nil) }
        let stems = Set(currentKeys.map(\.fileStem))
        let migratedFiles = Set(stems.flatMap { [$0 + ".png", $0 + ".json"] })
        let files = try files()
        #expect(files == migratedFiles)
        for old in [titleStem] + numberedStems {
            #expect(!files.contains(old + ".png") && !files.contains(old + ".json"))
        }

        // The next launch finds everything directly: same images, nothing moved or rewritten.
        let (relaunched, stillMissing) = await launch(path, items: items)
        #expect(stillMissing == [uncached.windowID])
        #expect(relaunched.styles == capturer.styles)
        #expect(try self.files() == migratedFiles)
    }

    /// Protects upgrades where an item's old entry can't be told apart yet: items sharing an identity (an app's item
    /// re-created while the old window lingers) are skipped and their earlier entries stay for a later launch, while
    /// the other items still load.
    @Test func sharedIdentitiesKeepTheirEarlierEntriesForLater() async throws {
        defer { cleanUp() }
        let appearance = ItemImageCapturer.currentAppearance
        let scale = Int(ItemImageCapturer(diskCache: nil).menuBarScale)
        let width = 22 * scale, height = 24 * scale
        let earlier = now.addingTimeInterval(-10 * 24 * 3600)
        let twinA = item(21, "com.example.Twin", key: "desc:Twin", title: "TwinItem")
        let twinB = item(22, "com.example.Twin", key: "desc:Twin", title: "TwinItem")
        let other = item(23, "com.example.Other", key: "desc:Other", title: "OtherItem")
        for (bundleID, title) in [("com.example.Twin", "TwinItem"), ("com.example.Other", "OtherItem")] {
            try write(Self.glyph(width: width, height: height),
                      metadata: MetadataV02(bundleID: bundleID, title: title, appearance: appearance, scale: scale,
                                            tone: .dark, style: .monochrome(.dark), pixelWidth: width,
                                            pixelHeight: height, capturedAt: earlier, lastSeen: earlier),
                      stem: Self.stem(bundleID: bundleID, discriminator: title, appearance: appearance, scale: scale))
        }
        let twinStem = Self.stem(bundleID: "com.example.Twin", discriminator: "TwinItem", appearance: appearance,
                                 scale: scale)

        let (capturer, missing) = await launch(.preloadThenOpen, items: [twinA, twinB, other])
        #expect(Set(missing) == [twinA.windowID, twinB.windowID])
        #expect(capturer.images[other.windowID] != nil)
        #expect(try files().contains(twinStem + ".json"))

        // Once only one of them is left, it takes the entry over.
        let (later, _) = await launch(.preloadThenOpen, items: [twinA, other])
        #expect(later.images[twinA.windowID] != nil)
        #expect(try !files().contains(twinStem + ".json"))
    }
}
