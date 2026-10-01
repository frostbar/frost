import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Menu bar appearance at capture time (glyph colors differ with it).
public enum MenuBarAppearance: String, Codable, Sendable {
    case light, dark
}

/// Disk cache key: an icon identity that is stable across launches + menu bar appearance + capture scale
/// (pixels / point).
public struct ItemImageCacheKey: Hashable, Sendable {
    public let identity: ItemIdentity
    public let appearance: MenuBarAppearance
    public let scale: Int

    public init(identity: ItemIdentity, appearance: MenuBarAppearance, scale: Int) {
        self.identity = identity
        self.appearance = appearance
        self.scale = scale
    }

    /// File name stem (without extension):
    /// `<sanitized bundle ID>-<first 16 hex digits of SHA-256(bundle ID + title)>-<appearance>@<scale>x`.
    /// The bundle ID prefix is only for human inspection (keeps only `[A-Za-z0-9._-]`, at most 60 characters);
    /// uniqueness comes from the hash, and the title (which may contain any characters) only goes into the hash.
    public var fileStem: String {
        "\(Self.sanitized(identity.bundleID))-\(Self.hash(identity))-\(appearance.rawValue)@\(scale)x"
    }

    static let maxPrefixLength = 60

    static func sanitized(_ text: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        var result = String(text.map { allowed.contains($0) ? $0 : "_" }.prefix(maxPrefixLength))
        // Must not start with a dot (avoids hidden files and `..`).
        while result.hasPrefix(".") { result.replaceSubrange(result.startIndex...result.startIndex, with: "_") }
        return result.isEmpty ? "_" : result
    }

    static func hash(_ identity: ItemIdentity) -> String {
        let digest = SHA256.hash(data: Data((identity.bundleID + "\u{0}" + identity.title).utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// A capture read from the disk cache, with its classification.
public struct CachedItemImage: Sendable {
    public let image: CGImage
    public let tone: GlyphTone
    public let style: GlyphStyle

    public init(image: CGImage, tone: GlyphTone, style: GlyphStyle) {
        self.image = image
        self.tone = tone
        self.style = style
    }
}

/// Disk cache of menu bar item captures (default `~/Library/Caches/dev.frost.Frost/items/`).
///
/// Hidden items that are pushed out can only be captured after a temporary menu bar expand, and the in-memory cache
/// is empty after every Frost relaunch. The disk cache means items already captured don't need another expand after
/// a relaunch. Two files per item: `<fileStem>.png` (the capture) and `<fileStem>.json` (`Metadata`: identity,
/// appearance, scale, glyph tone and classification, pixel size, last seen time).
///
/// All methods are synchronous file operations callable from any thread; writes are atomic (the PNG is written
/// before the metadata, and reads go by the metadata).
public struct ItemImageDiskCache: Sendable {
    /// Items not seen (captured or read) for longer than this are deleted by `prune`.
    public static let maxAge: TimeInterval = 30 * 24 * 3600
    /// `touch` only rewrites the metadata when `lastSeen` is older than this (avoids a disk write on every read).
    static let touchInterval: TimeInterval = 24 * 3600
    static let formatVersion = 1

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Caches/dev.frost.Frost/items/`.
    public static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "dev.frost.Frost", directoryHint: .isDirectory)
            .appending(path: "items", directoryHint: .isDirectory)
    }

    struct Metadata: Codable, Equatable {
        var version: Int
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

    public func imageURL(for key: ItemImageCacheKey) -> URL {
        directory.appending(path: key.fileStem + ".png", directoryHint: .notDirectory)
    }

    public func metadataURL(for key: ItemImageCacheKey) -> URL {
        directory.appending(path: key.fileStem + ".json", directoryHint: .notDirectory)
    }

    // MARK: - Writing

    /// Saves (overwrites) a capture.
    public func save(_ image: CGImage, tone: GlyphTone, style: GlyphStyle, for key: ItemImageCacheKey,
                     now: Date = Date()) throws {
        guard let png = Self.pngData(image) else { throw CocoaError(.fileWriteUnknown) }
        let metadata = Metadata(version: Self.formatVersion, bundleID: key.identity.bundleID, title: key.identity.title,
                                appearance: key.appearance, scale: key.scale, tone: tone, style: style,
                                pixelWidth: image.width, pixelHeight: image.height, capturedAt: now, lastSeen: now)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: imageURL(for: key), options: .atomic)
        try Self.encoder.encode(metadata).write(to: metadataURL(for: key), options: .atomic)
    }

    /// Records that these items were just seen (for `prune`). Entries whose `lastSeen` is less than `touchInterval`
    /// before `now` are not rewritten.
    public func touch(_ keys: [ItemImageCacheKey], now: Date = Date()) {
        for key in keys {
            let url = metadataURL(for: key)
            guard var metadata = readMetadata(url), now.timeIntervalSince(metadata.lastSeen) >= Self.touchInterval
            else { continue }
            metadata.lastSeen = now
            try? Self.encoder.encode(metadata).write(to: url, options: .atomic)
        }
    }

    // MARK: - Reading

    /// Reads one item; returns nil when it is missing, corrupt, or doesn't match the key (hash collision, size
    /// mismatch).
    public func load(_ key: ItemImageCacheKey) -> CachedItemImage? {
        guard let metadata = readMetadata(metadataURL(for: key)),
              metadata.version == Self.formatVersion,
              metadata.bundleID == key.identity.bundleID, metadata.title == key.identity.title,
              metadata.appearance == key.appearance, metadata.scale == key.scale,
              let data = try? Data(contentsOf: imageURL(for: key)),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == metadata.pixelWidth, image.height == metadata.pixelHeight
        else { return nil }
        return CachedItemImage(image: image, tone: metadata.tone, style: metadata.style)
    }

    // MARK: - Pruning

    /// Deletes items not seen for longer than `maxAge`, unreadable metadata, and PNGs that have no metadata and are
    /// equally expired. Returns the deleted file stems.
    @discardableResult
    public func prune(now: Date = Date(), maxAge: TimeInterval = maxAge) -> [String] {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: directory,
                                                               includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        var removed: [String] = []
        let stems = Set(files.map { $0.deletingPathExtension().lastPathComponent })
        for stem in stems.sorted() {
            let json = directory.appending(path: stem + ".json", directoryHint: .notDirectory)
            let png = directory.appending(path: stem + ".png", directoryHint: .notDirectory)
            let lastSeen: Date?
            if fileManager.fileExists(atPath: json.path) {
                // Corrupt metadata: treat as expired.
                lastSeen = readMetadata(json)?.lastSeen ?? .distantPast
            } else {
                // Only a PNG (possibly mid-write): judge by the file's modification date.
                lastSeen = (try? png.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }
            guard let lastSeen, now.timeIntervalSince(lastSeen) > maxAge else { continue }
            try? fileManager.removeItem(at: json)
            try? fileManager.removeItem(at: png)
            removed.append(stem)
        }
        return removed
    }

    // MARK: - Helpers

    private func readMetadata(_ url: URL) -> Metadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(Metadata.self, from: data)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString,
                                                                 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
