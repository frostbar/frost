import Testing
import CoreGraphics
import Foundation
@testable import FrostCore

@Suite struct ItemImageCacheKeyTests {
    let identity = ItemIdentity(bundleID: "com.example.App", key: "Item-0")

    @Test func stemIsStableAndReadable() {
        let key = ItemImageCacheKey(identity: identity, appearance: .dark, scale: 2)
        #expect(key.fileStem == ItemImageCacheKey(identity: identity, appearance: .dark, scale: 2).fileStem)
        #expect(key.fileStem.hasPrefix("com.example.App-"))
        #expect(key.fileStem.hasSuffix("-dark@2x"))
        // Prefix + 16-hex-digit hash + appearance / scale.
        let parts = key.fileStem.split(separator: "-")
        #expect(parts.count == 3)
        #expect(parts[1].count == 16)
        #expect(parts[1].allSatisfy { $0.isHexDigit })
    }

    @Test func appearanceAndScaleAreSeparateEntries() {
        let stems = Set([
            ItemImageCacheKey(identity: identity, appearance: .dark, scale: 2),
            ItemImageCacheKey(identity: identity, appearance: .light, scale: 2),
            ItemImageCacheKey(identity: identity, appearance: .dark, scale: 1),
        ].map(\.fileStem))
        #expect(stems.count == 3)
    }

    @Test func keyOnlyAffectsTheHash() {
        let a = ItemImageCacheKey(identity: ItemIdentity(bundleID: "com.example.App", key: "Item-0"),
                                  appearance: .light, scale: 2)
        let b = ItemImageCacheKey(identity: ItemIdentity(bundleID: "com.example.App", key: "Item-1"),
                                  appearance: .light, scale: 2)
        #expect(a.fileStem != b.fileStem)
        #expect(!a.fileStem.contains("Item"))
    }

    @Test func bundleIDAndKeyDoNotCollideAcrossTheSeparator() {
        let a = ItemIdentity(bundleID: "com.a", key: "b.c")
        let b = ItemIdentity(bundleID: "com.a.b", key: "c")
        #expect(ItemImageCacheKey.hash(a) != ItemImageCacheKey.hash(b))
    }

    @Test func unsafeCharactersAreSanitized() {
        let identity = ItemIdentity(bundleID: "../evil/../../com app:😀", key: "a/b")
        let stem = ItemImageCacheKey(identity: identity, appearance: .light, scale: 2).fileStem
        #expect(!stem.contains("/"))
        #expect(!stem.contains(":"))
        #expect(!stem.contains(" "))
        #expect(!stem.hasPrefix("."))
        #expect(stem.unicodeScalars.allSatisfy { $0.isASCII })
        #expect(ItemImageCacheKey.sanitized("") == "_")
    }

    @Test func longBundleIDsAreTruncated() {
        let identity = ItemIdentity(bundleID: String(repeating: "a", count: 300), key: "")
        let stem = ItemImageCacheKey(identity: identity, appearance: .light, scale: 3).fileStem
        #expect(stem.count == ItemImageCacheKey.maxPrefixLength + 1 + 16 + "-light@3x".count)
    }

    @Test func pathsLiveInTheCacheDirectory() {
        let cache = ItemImageDiskCache(directory: URL(filePath: "/tmp/frost-items", directoryHint: .isDirectory))
        let key = ItemImageCacheKey(identity: identity, appearance: .dark, scale: 2)
        #expect(cache.imageURL(for: key).path == "/tmp/frost-items/\(key.fileStem).png")
        #expect(cache.metadataURL(for: key).path == "/tmp/frost-items/\(key.fileStem).json")
    }

    @Test func defaultDirectoryIsInUserCaches() throws {
        let directory = try #require(ItemImageDiskCache.defaultDirectory)
        #expect(directory.path.hasSuffix("/Library/Caches/dev.frost.Frost/items"))
    }
}

@Suite struct ItemImageDiskCacheTests {
    let directory: URL
    let cache: ItemImageDiskCache
    let key = ItemImageCacheKey(identity: ItemIdentity(bundleID: "com.example.App", key: "desc:Item-0"),
                                appearance: .dark, scale: 2)
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    init() {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "FrostCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "items", directoryHint: .isDirectory)
        cache = ItemImageDiskCache(directory: directory)
    }

    /// 4×2 test image: left half opaque white, top-right corner red, the rest transparent.
    static func sampleImage() -> CGImage {
        let width = 4, height = 2
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<2 { pixels.replaceSubrange((y * width + x) * 4..<(y * width + x) * 4 + 4, with: [255, 255, 255, 255]) }
        }
        pixels.replaceSubrange(3 * 4..<4 * 4, with: [255, 0, 0, 255])
        return pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    @Test func roundTrip() throws {
        defer { cleanUp() }
        let image = Self.sampleImage()
        try cache.save(image, tone: .light, style: .colored(plate: .light), for: key, now: now)
        #expect(FileManager.default.fileExists(atPath: cache.imageURL(for: key).path))
        #expect(FileManager.default.fileExists(atPath: cache.metadataURL(for: key).path))
        let loaded = try #require(cache.load(key))
        #expect(loaded.tone == .light)
        #expect(loaded.style == .colored(plate: .light))
        #expect(loaded.image.width == 4 && loaded.image.height == 2)
        #expect(GlyphPixels.rgba(loaded.image) == GlyphPixels.rgba(image))
    }

    @Test func monochromeStyleRoundTrips() throws {
        defer { cleanUp() }
        try cache.save(Self.sampleImage(), tone: .dark, style: .monochrome(.dark), for: key, now: now)
        #expect(cache.load(key)?.style == .monochrome(.dark))
        #expect(cache.load(key)?.tone == .dark)
    }

    @Test func freshCaptureOverwrites() throws {
        defer { cleanUp() }
        try cache.save(Self.sampleImage(), tone: .light, style: .monochrome(.light), for: key, now: now)
        try cache.save(Self.sampleImage(), tone: .dark, style: .colored(plate: nil), for: key, now: now)
        #expect(cache.load(key)?.tone == .dark)
        #expect(cache.load(key)?.style == .colored(plate: nil))
    }

    @Test func missingEntriesAndOtherKeysLoadNothing() throws {
        defer { cleanUp() }
        #expect(cache.load(key) == nil)
        try cache.save(Self.sampleImage(), tone: .light, style: .monochrome(.light), for: key, now: now)
        #expect(cache.load(ItemImageCacheKey(identity: key.identity, appearance: .light, scale: 2)) == nil)
        #expect(cache.load(ItemImageCacheKey(identity: key.identity, appearance: .dark, scale: 1)) == nil)
        #expect(cache.load(ItemImageCacheKey(identity: ItemIdentity(bundleID: "com.example.App", key: "Item-1"),
                                             appearance: .dark, scale: 2)) == nil)
    }

    @Test func corruptEntriesLoadNothing() throws {
        defer { cleanUp() }
        try cache.save(Self.sampleImage(), tone: .light, style: .monochrome(.light), for: key, now: now)
        try Data("not a png".utf8).write(to: cache.imageURL(for: key))
        #expect(cache.load(key) == nil)
        try cache.save(Self.sampleImage(), tone: .light, style: .monochrome(.light), for: key, now: now)
        try Data("{".utf8).write(to: cache.metadataURL(for: key))
        #expect(cache.load(key) == nil)
    }

    @Test func pruneRemovesEntriesNotSeenFor30Days() throws {
        defer { cleanUp() }
        let old = ItemImageCacheKey(identity: ItemIdentity(bundleID: "com.example.Old", key: "x"),
                                    appearance: .light, scale: 2)
        try cache.save(Self.sampleImage(), tone: .light, style: .monochrome(.light), for: old,
                       now: now.addingTimeInterval(-31 * 24 * 3600))
        try cache.save(Self.sampleImage(), tone: .light, style: .monochrome(.light), for: key,
                       now: now.addingTimeInterval(-29 * 24 * 3600))
        let removed = cache.prune(now: now)
        #expect(removed == [old.fileStem])
        #expect(cache.load(old) == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.imageURL(for: old).path))
        #expect(cache.load(key) != nil)
    }

    @Test func touchKeepsEntriesAlive() throws {
        defer { cleanUp() }
        try cache.save(Self.sampleImage(), tone: .light, style: .monochrome(.light), for: key,
                       now: now.addingTimeInterval(-31 * 24 * 3600))
        cache.touch([key], now: now)
        #expect(cache.prune(now: now).isEmpty)
        #expect(cache.load(key) != nil)
    }

    @Test func pruneRemovesCorruptMetadata() throws {
        defer { cleanUp() }
        try cache.save(Self.sampleImage(), tone: .light, style: .monochrome(.light), for: key, now: now)
        try Data("{".utf8).write(to: cache.metadataURL(for: key))
        #expect(cache.prune(now: now) == [key.fileStem])
        #expect(!FileManager.default.fileExists(atPath: cache.imageURL(for: key).path))
    }

    @Test func pruneOfAMissingDirectoryDoesNothing() {
        #expect(cache.prune(now: now).isEmpty)
    }

    // MARK: Entries written before identity keys existed

    /// Writes an entry the way versions keyed by window title did: stem hash of bundle ID + title, metadata with a
    /// `title` and no `key`.
    private func writeVersion1Entry(bundleID: String, title: String, appearance: MenuBarAppearance = .dark,
                                    scale: Int = 2) throws -> ItemImageCacheKey {
        let legacy = ItemImageCacheKey(identity: IdentityMigration.legacy(bundleID: bundleID, title: title),
                                       appearance: appearance, scale: scale)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(ItemImageDiskCache.pngData(Self.sampleImage())).write(to: cache.imageURL(for: legacy))
        let json = """
            {"appearance":"\(appearance.rawValue)","bundleID":"\(bundleID)","capturedAt":"2026-01-01T00:00:00Z",\
            "lastSeen":"2026-01-01T00:00:00Z","pixelHeight":2,"pixelWidth":4,"scale":\(scale),\
            "style":{"monochrome":{"_0":"light"}},"title":"\(title)","tone":"light","version":1}
            """
        try Data(json.utf8).write(to: cache.metadataURL(for: legacy))
        return legacy
    }

    @Test func legacyKeysHashTheBareTitleLikeVersion1() {
        // Version 1 named entries by SHA-256(bundle ID + NUL + title).
        let legacy = IdentityMigration.legacy(bundleID: "com.a", title: "Item-0")
        let bare = ItemIdentity(bundleID: "com.a", key: "Item-0")
        #expect(ItemImageCacheKey.hash(legacy) == ItemImageCacheKey.hash(bare))
        #expect(ItemImageCacheKey.hash(legacy) != ItemImageCacheKey.hash(ItemIdentity(bundleID: "com.a",
                                                                                         key: "desc:Item-0")))
    }

    @Test func version1EntriesLoadUnderTheirLegacyKey() throws {
        defer { cleanUp() }
        let legacy = try writeVersion1Entry(bundleID: "com.example.App", title: "Item-0")
        #expect(cache.load(legacy)?.tone == .light)
        // Not under the item's new identity until migrated.
        #expect(cache.load(key) == nil)
    }

    @Test func migrationMovesAVersion1EntryToTheNewKey() throws {
        defer { cleanUp() }
        let legacy = try writeVersion1Entry(bundleID: "com.example.App", title: "Item-0")
        let migrated = try #require(cache.migrate(from: legacy, to: key, now: now))
        #expect(migrated.image.width == 4)
        #expect(cache.load(key)?.style == .monochrome(.light))
        #expect(cache.load(legacy) == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.imageURL(for: legacy).path))
        // Migrating counts as seeing the entry.
        #expect(cache.prune(now: now).isEmpty)
    }

    @Test func earlierKeysAreTheTitleAndTheNumberedKey() {
        let item = MenuBarItem(windowID: 1, frame: .zero, isOnScreen: true, windowTitle: "Fan", bundleID: "com.a",
                               pid: 1, axDescription: nil, identityKey: "desc:Fan <n>#0",
                               numberedIdentityKey: "desc:Fan 1")
        let current = ItemImageCacheKey(identity: item.identity!, appearance: .dark, scale: 2)
        #expect(current.earlierKeys(of: item).map(\.identity)
                == [IdentityMigration.legacy(bundleID: "com.a", title: "Fan"),
                    ItemIdentity(bundleID: "com.a", key: "desc:Fan 1")])
        #expect(current.earlierKeys(of: item).allSatisfy { $0.appearance == .dark && $0.scale == 2 })
        let plain = MenuBarItem(windowID: 2, frame: .zero, isOnScreen: true, windowTitle: "", bundleID: "com.a",
                                pid: 1, axDescription: nil, identityKey: "desc:B")
        #expect(ItemImageCacheKey(identity: plain.identity!, appearance: .dark, scale: 2).earlierKeys(of: plain)
                .isEmpty)
    }

    @Test func anEntryUnderANumberedKeyMovesToTheNormalizedKey() throws {
        defer { cleanUp() }
        let numbered = ItemImageCacheKey(identity: ItemIdentity(bundleID: "com.example.App", key: "desc:Fan 1"),
                                         appearance: .dark, scale: 2)
        let normalized = ItemImageCacheKey(identity: ItemIdentity(bundleID: "com.example.App", key: "desc:Fan <n>#0"),
                                           appearance: .dark, scale: 2)
        try cache.save(Self.sampleImage(), tone: .light, style: .monochrome(.light), for: numbered, now: now)
        #expect(cache.load(normalized) == nil)
        #expect(cache.migrate(from: numbered, to: normalized, now: now) != nil)
        #expect(cache.load(normalized)?.style == .monochrome(.light))
        #expect(cache.load(numbered) == nil)
    }

    @Test func migrationWithoutALegacyEntryDoesNothing() throws {
        defer { cleanUp() }
        let legacy = ItemImageCacheKey(identity: IdentityMigration.legacy(bundleID: "com.example.App", title: "x"),
                                       appearance: .dark, scale: 2)
        #expect(cache.migrate(from: legacy, to: key) == nil)
        #expect(cache.load(key) == nil)
    }
}
