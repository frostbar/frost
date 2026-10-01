import Testing
import CoreGraphics
import Foundation
@testable import FrostCore

@Suite struct ItemImageCacheKeyTests {
    let identity = ItemIdentity(bundleID: "com.example.App", title: "Item-0")

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

    @Test func titleOnlyAffectsTheHash() {
        let a = ItemImageCacheKey(identity: ItemIdentity(bundleID: "com.example.App", title: "Item-0"),
                                  appearance: .light, scale: 2)
        let b = ItemImageCacheKey(identity: ItemIdentity(bundleID: "com.example.App", title: "Item-1"),
                                  appearance: .light, scale: 2)
        #expect(a.fileStem != b.fileStem)
        #expect(!a.fileStem.contains("Item"))
    }

    @Test func bundleIDAndTitleDoNotCollideAcrossTheSeparator() {
        let a = ItemIdentity(bundleID: "com.a", title: "b.c")
        let b = ItemIdentity(bundleID: "com.a.b", title: "c")
        #expect(ItemImageCacheKey.hash(a) != ItemImageCacheKey.hash(b))
    }

    @Test func unsafeCharactersAreSanitized() {
        let identity = ItemIdentity(bundleID: "../evil/../../com app:😀", title: "a/b")
        let stem = ItemImageCacheKey(identity: identity, appearance: .light, scale: 2).fileStem
        #expect(!stem.contains("/"))
        #expect(!stem.contains(":"))
        #expect(!stem.contains(" "))
        #expect(!stem.hasPrefix("."))
        #expect(stem.unicodeScalars.allSatisfy { $0.isASCII })
        #expect(ItemImageCacheKey.sanitized("") == "_")
    }

    @Test func longBundleIDsAreTruncated() {
        let identity = ItemIdentity(bundleID: String(repeating: "a", count: 300), title: "")
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
    let key = ItemImageCacheKey(identity: ItemIdentity(bundleID: "com.example.App", title: "Item-0"),
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
        #expect(cache.load(ItemImageCacheKey(identity: ItemIdentity(bundleID: "com.example.App", title: "Item-1"),
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
        let old = ItemImageCacheKey(identity: ItemIdentity(bundleID: "com.example.Old", title: "x"),
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
}
