import AppKit
import ScreenCaptureKit
import Observation

/// Captures menu bar item images with ScreenCaptureKit, cached by windowID (glyph `tones` are cached too).
///
/// Captures are also persisted to disk (`ItemImageDiskCache`, keyed by `ItemIdentity` + menu bar appearance + scale):
/// after Frost relaunches, `missing(_:)` / `loadCached(_:)` first fill in the current items' images from disk; only
/// items that are not on disk either need a temporary menu bar expansion to capture.
///
/// Captures are always rendered at the item's size in points:
/// `Image(decorative: cgImage, scale: 1).resizable().frame(width: item.frame.width, height: item.frame.height)`.
@MainActor
@Observable
public final class ItemImageCapturer {
    public private(set) var images: [CGWindowID: CGImage] = [:]
    /// One-to-one with `images`: each capture's glyph tone, used to pick the tile background.
    public private(set) var tones: [CGWindowID: GlyphTone] = [:]
    /// One-to-one with `images`: monochrome glyph / colored icon (`GlyphStyle`); decides how Frost Bar shows
    /// the capture.
    public private(set) var styles: [CGWindowID: GlyphStyle] = [:]
    /// Template image of a monochrome glyph (`GlyphMask`), tinted with the foreground color by Frost Bar;
    /// nil for colored icons.
    public private(set) var templates: [CGWindowID: CGImage] = [:]
    /// One-to-one with `images`: the capture's size (points, i.e. captured pixels ÷ scale). Frost Bar displays the
    /// capture and sizes the tile by this rather than by the item's current frame: the layout is frozen during live
    /// refresh, so a new capture of an item whose width changed (e.g. longer text) is not stretched.
    public private(set) var sizes: [CGWindowID: CGSize] = [:]

    /// `SCShareableContent` cache used for captures (the freeze frame uses it too).
    @ObservationIgnored public let contentCache = ShareableContentCache()
    /// Each capture's pixels (`PixelCopy.bytes`), used to detect "the new capture is identical to the existing one".
    @ObservationIgnored private var pixels: [CGWindowID: Data] = [:]
    @ObservationIgnored private var lastFallbackCount = 0
    /// Number of items captured per window in the most recent `capture` (strip capture failed or the frame changed
    /// around the capture); for statistics.
    @ObservationIgnored public private(set) var lastPerWindowCount = 0
    /// Debug: log items whose frame is inconsistent during strip capture (`FROST_LIVE_REFRESH_TRACE=1`).
    @ObservationIgnored public var traceStripMismatches = false
    /// Display hosting the scanned menu bar (the active menu bar, `MenuBarItemScanner.menuBarDisplay`); strip capture
    /// and scale follow it. Injected by the app layer; defaults to the main display.
    @ObservationIgnored public var menuBarDisplayID: () -> CGDirectDisplayID = { CGMainDisplayID() }

    /// Incremented on appearance changes; if it changes during a capture, that round's (old-appearance) results
    /// are discarded.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?

    /// nil = no disk cache.
    @ObservationIgnored private let diskCache: ItemImageDiskCache?
    @ObservationIgnored private var didPrune = false
    /// Keys already looked up on disk this run with no usable entry (avoids rereading the disk every time the panel
    /// opens). Removed once a new capture is taken.
    @ObservationIgnored private var diskMisses: Set<ItemImageCacheKey> = []

    public init(diskCache: ItemImageDiskCache? = ItemImageDiskCache.defaultDirectory.map(ItemImageDiskCache.init)) {
        self.diskCache = diskCache
        // Glyph colors change with the appearance (light/dark), so clear the cache.
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
        // KVO callbacks have no thread guarantee; hop back to the main actor.
            Task { @MainActor in self?.invalidate() }
        }
    }

    /// Clears all in-memory caches (the disk cache is stored per appearance and is unaffected).
    public func invalidate() {
        generation += 1
        images.removeAll()
        tones.removeAll()
        styles.removeAll()
        templates.removeAll()
        sizes.removeAll()
        pixels.removeAll()
        diskMisses.removeAll()
    }

    /// Returns the items in `images` that have no capture yet, for the caller to capture one by one. Fills from the
    /// disk cache first (see `loadCached(_:)`).
    public func missing(_ items: [MenuBarItem]) -> [MenuBarItem] {
        loadCached(items)
        return items.filter { images[$0.windowID] == nil }
    }

    /// Fills in, from the disk cache, items in `items` that have no capture yet (entries for the current menu bar
    /// appearance and the scanned display's scale).
    ///
    /// Skips: items with unknown ownership (unstable identity); items whose identity is duplicated within `items`
    /// (indistinguishable); entries whose pixel size does not match the item's current frame (e.g. a text item's
    /// content changed). On the first call, prunes entries not seen for 30 days in the background.
    public func loadCached(_ items: [MenuBarItem]) {
        guard let diskCache else { return }
        if !didPrune {
            didPrune = true
            Task.detached(priority: .utility) { diskCache.prune() }
        }
        let appearance = Self.currentAppearance
        let scale = menuBarScale
        let counts = Dictionary(items.map { ($0.identity, 1) }, uniquingKeysWith: +)
        var loaded: [ItemImageCacheKey] = []
        for item in items where images[item.windowID] == nil && item.bundleID != nil && counts[item.identity] == 1 {
            let key = ItemImageCacheKey(identity: item.identity, appearance: appearance, scale: Int(scale))
            guard !diskMisses.contains(key) else { continue }
            guard let cached = diskCache.load(key),
                  abs(cached.image.width - Int((item.frame.width * scale).rounded())) <= 1,
                  abs(cached.image.height - Int((item.frame.height * scale).rounded())) <= 1
            else {
                diskMisses.insert(key)
                continue
            }
            store(cached.image, tone: cached.tone, style: cached.style, scale: scale, for: item.windowID)
            loaded.append(key)
        }
        guard !loaded.isEmpty else { return }
        FrostLog.capture.notice("loaded \(loaded.count) item image(s) from the disk cache")
        Task.detached(priority: .utility) { diskCache.touch(loaded) }
    }

    /// Captures the given items (may be a subset of all items, e.g. the result of `missing(_:)`) and returns the
    /// captured ones. Only items with `isOnScreen == true` are captured: capturing an off-screen window (pushed out /
    /// under the notch) fails (SCStream −3811), and those items keep their old cache.
    ///
    /// First captures one menu bar strip covering these items (containing only their windows, transparent background;
    /// see `StripCrop`), then crops each item by its frame; items whose frame differs before and after the capture
    /// (still moving) or that cannot be cropped fall back to per-window capture. Items whose pixels are identical to
    /// the existing capture are not updated (no redraw, no reclassification, no disk write): Frost Bar's live refresh
    /// captures once per second and the vast majority of icons do not change.
    ///
    /// Caches of windows that no longer exist are cleared; caches of still-existing windows outside the given set are
    /// kept. New captures are also written to the disk cache (overwriting old entries).
    @discardableResult
    public func capture(_ items: [MenuBarItem]) async -> Set<CGWindowID> {
        guard CGPreflightScreenCaptureAccess() else { return [] }
        let startGeneration = generation
        let appearance = Self.currentAppearance
        let targets = items.filter(\.isOnScreen)
        guard let content = await contentCache.content(containing: Set(targets.map(\.windowID))) else { return [] }
        let windows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        let scale = menuBarScale
        let strip = await captureStrip(targets, windows: windows, displays: content.displays, scale: scale)
        var fresh = strip.images
        // Latest frame of each item (per-window capture sizes by it).
        var latest = targets
        if !strip.moved.isEmpty {
            // Some items moved during the capture (e.g. a text item on the left just got wider, shifting the items
            // after it): capture the strip again at the moved frames, which have usually settled; only items that
            // are still inconsistent are captured one by one.
            let moved = Dictionary(strip.moved.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
            latest = targets.map { moved[$0.windowID] ?? $0 }
            let retried = await captureStrip(strip.moved, windows: windows, displays: content.displays, scale: scale)
            fresh.merge(retried.images) { _, new in new }
        }
        let leftovers = latest.filter { fresh[$0.windowID] == nil }
        lastPerWindowCount = leftovers.count
        // Capture per window the items whose strip capture failed or whose frame changed during the capture (log the
        // same count only once: live refresh reaches this every second).
        if leftovers.count != lastFallbackCount {
            lastFallbackCount = leftovers.count
            if !leftovers.isEmpty {
                FrostLog.capture.notice(
                    "capturing \(leftovers.count) of \(targets.count) item(s) per window (strip capture unavailable for them)")
            }
        }
        for item in leftovers {
            guard let window = windows[item.windowID] else { continue }
            let config = SCStreamConfiguration()
            config.width = Int(item.frame.width * scale)
            config.height = Int(item.frame.height * scale)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            let filter = SCContentFilter(desktopIndependentWindow: window)
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                fresh[item.windowID] = image
            }
        }
        guard generation == startGeneration else { return [] }
        var toSave: [(ItemImageCacheKey, CGImage, GlyphTone, GlyphStyle)] = []
        let counts = Dictionary(items.map { ($0.identity, 1) }, uniquingKeysWith: +)
        for item in items {
            guard let captured = fresh[item.windowID], let copy = PixelCopy(captured) else { continue }
            // Pixel-identical to the existing capture: leave it as is.
            if pixels[item.windowID] == copy.bytes, images[item.windowID] != nil { continue }
            let style = GlyphStyle.of(copy.image)
            let tone = GlyphTone.of(copy.image)
            store(copy.image, tone: tone, style: style, scale: scale, for: item.windowID)
            pixels[item.windowID] = copy.bytes
            guard item.bundleID != nil, counts[item.identity] == 1 else { continue }
            let key = ItemImageCacheKey(identity: item.identity, appearance: appearance, scale: Int(scale))
            diskMisses.remove(key)
            toSave.append((key, copy.image, tone, style))
        }
        // Prune by the status bar windows that still exist in the system (not by the given items), so capturing a
        // subset does not clear other items' caches. Do not assign when nothing changed (the assignment itself
        // notifies observers and makes Frost Bar redraw).
        let existing = Set(StatusWindowParser.currentWindows().map(\.windowID))
        if images.keys.contains(where: { !existing.contains($0) }) {
            images = images.filter { existing.contains($0.key) }
            tones = tones.filter { images[$0.key] != nil }
            styles = styles.filter { images[$0.key] != nil }
            templates = templates.filter { images[$0.key] != nil }
            sizes = sizes.filter { images[$0.key] != nil }
            pixels = pixels.filter { images[$0.key] != nil }
        }
        if let diskCache, !toSave.isEmpty {
            Task.detached(priority: .utility) {
                for (key, image, tone, style) in toSave {
                    do {
                        try diskCache.save(image, tone: tone, style: style, for: key)
                    } catch {
                        FrostLog.capture.error("could not write \(key.fileStem, privacy: .private) to the image cache: \(error, privacy: .public)")
                    }
                }
            }
        }
        return Set(fresh.keys)
    }

    /// Captures one menu bar strip covering `targets` (on the scanned display; only these windows, transparent
    /// background) and crops each item by its frame. Items whose frame differs before and after the capture get no
    /// image; instead they are returned in `moved` with their post-capture frame (the caller can retry with it).
    private func captureStrip(_ targets: [MenuBarItem], windows: [CGWindowID: SCWindow], displays: [SCDisplay],
                              scale: CGFloat) async -> (images: [CGWindowID: CGImage], moved: [MenuBarItem]) {
        let displayID = menuBarDisplayID()
        let bounds = CGDisplayBounds(displayID)
        let included = targets.compactMap { windows[$0.windowID] }
        guard !included.isEmpty, let display = displays.first(where: { $0.displayID == displayID }),
              let rect = StripCrop.stripRect(covering: targets.map(\.frame), display: bounds)
        else { return ([:], []) }
        let ids = Set(targets.map(\.windowID))
        func currentFrames() -> [CGWindowID: CGRect] {
            Dictionary(StatusWindowParser.currentWindows().filter { ids.contains($0.windowID) }
                .map { ($0.windowID, $0.frame) }, uniquingKeysWith: { a, _ in a })
        }
        let before = currentFrames()
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = Int((rect.width * scale).rounded())
        config.height = Int((rect.height * scale).rounded())
        config.showsCursor = false
        config.backgroundColor = .clear
        config.ignoreShadowsDisplay = true
        let filter = SCContentFilter(display: display, including: included)
        let strip: CGImage
        do {
            strip = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            FrostLog.capture.error("strip capture failed: \(error, privacy: .public)")
            return ([:], [])
        }
        let after = currentFrames()
        let origin = CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY)
        let size = CGSize(width: strip.width, height: strip.height)
        var result: [CGWindowID: CGImage] = [:]
        if traceStripMismatches {
            for item in targets where before[item.windowID] != item.frame || after[item.windowID] != item.frame {
                let scanned = "\(item.frame)"
                let earlier = before[item.windowID].map { "\($0)" } ?? "-"
                let later = after[item.windowID].map { "\($0)" } ?? "-"
                FrostLog.capture.info("""
                    strip capture: item \(item.windowID) moved (scan \(scanned, privacy: .public), \
                    before \(earlier, privacy: .public), after \(later, privacy: .public))
                    """)
            }
        }
        for item in targets where before[item.windowID] == item.frame && after[item.windowID] == item.frame {
            guard let pixels = StripCrop.pixelRect(of: item.frame, stripOrigin: origin, scale: scale, imageSize: size),
                  let crop = strip.cropping(to: pixels) else { continue }
            result[item.windowID] = crop
        }
        let moved = targets.compactMap { item -> MenuBarItem? in
            guard result[item.windowID] == nil, let frame = after[item.windowID], frame != item.frame else { return nil }
            return item.with(frame: frame)
        }
        return (result, moved)
    }

    private func store(_ image: CGImage, tone: GlyphTone, style: GlyphStyle, scale: CGFloat, for id: CGWindowID) {
        images[id] = image
        tones[id] = tone
        styles[id] = style
        sizes[id] = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        if case .monochrome(let tone) = style {
            templates[id] = GlyphMask.make(from: image, tone: tone)
        } else {
            templates[id] = nil
        }
    }

    /// The current menu bar appearance (part of the disk cache key): judged by the app's appearance, consistent with
    /// the in-memory cache's invalidation condition (`effectiveAppearance`).
    private static var currentAppearance: MenuBarAppearance {
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    /// Scale of the display hosting the scanned menu bar (not NSScreen.main: that is the screen with the
    /// key window).
    private var menuBarScale: CGFloat {
        let displayID = menuBarDisplayID()
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }?.backingScaleFactor ?? 2
    }
}

/// A standalone copy of a capture (not referencing the strip capture's whole pixel buffer) and its pixel bytes, used
/// to compare whether two captures are identical. Copied in the original color space (no color conversion), so it
/// looks the same as a per-window capture.
struct PixelCopy {
    let image: CGImage
    let bytes: Data

    init?(_ source: CGImage) {
        let width = source.width, height = source.height
        guard width > 0, height > 0 else { return nil }
        var space = source.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        if space.model != .rgb { space = CGColorSpaceCreateDeviceRGB() }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = context.data
        else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        self.image = image
        bytes = Data(bytes: data, count: context.bytesPerRow * height)
    }
}
