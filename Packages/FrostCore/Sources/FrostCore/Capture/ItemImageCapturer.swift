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
    /// Expired entries are pruned at the first disk cache access, then once a day.
    @ObservationIgnored private var pruneSchedule = PeriodicSchedule(interval: .seconds(24 * 3600))
    /// Disk writes per item at most once per `diskWriteInterval` (live refresh recaptures changing icons every
    /// second); the newest held-back capture is written when due, or by `flushDiskCache()`.
    @ObservationIgnored private var diskWrites = DiskWriteThrottle<ItemImageCacheKey, DiskWrite>(
        interval: ItemImageCapturer.diskWriteInterval)
    public static let diskWriteInterval: Duration = .seconds(60)

    /// A capture to write to the disk cache.
    struct DiskWrite: Sendable {
        let image: CGImage
        let tone: GlyphTone
        let style: GlyphStyle
    }
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
    /// appearance and the scanned display's scale). Synchronous: the Frost Bar calls it right before showing the panel
    /// for anything `preloadCached(_:)` hasn't loaded yet.
    ///
    /// Skips: items with unknown ownership (unstable identity); items whose identity is duplicated within `items`
    /// (indistinguishable); entries whose pixel size does not match the item's current frame (e.g. a text item's
    /// content changed). Prunes entries not seen for 30 days in the background (at most once a day).
    public func loadCached(_ items: [MenuBarItem]) {
        guard let diskCache else { return }
        let requests = cacheRequests(items)
        guard !requests.isEmpty else { return }
        let prepared = requests.map { Self.prepare($0, from: diskCache) }
        apply(prepared, for: requests, from: diskCache, generation: generation)
    }

    /// Like `loadCached(_:)`, but reads, decodes and classifies the entries off the main actor, so it can run at launch
    /// without blocking the main thread: the Frost Bar's first open then finds the images in memory and shows them
    /// already decoded. Items captured meanwhile keep their fresh capture; an appearance change during the load
    /// discards the result.
    public func preloadCached(_ items: [MenuBarItem]) async {
        guard let diskCache else { return }
        let requests = cacheRequests(items)
        guard !requests.isEmpty else { return }
        let startGeneration = generation
        let prepared = await Task.detached(priority: .userInitiated) {
            requests.map { Self.prepare($0, from: diskCache) }
        }.value
        apply(prepared, for: requests, from: diskCache, generation: startGeneration)
    }

    /// One disk cache lookup: the item, its key, and the pixel size its capture must have.
    struct CacheRequest: Sendable {
        let windowID: CGWindowID
        let key: ItemImageCacheKey
        let pixelWidth: Int
        let pixelHeight: Int
        let scale: CGFloat
    }

    /// A disk-cached capture ready to store: decoded and copied (`PixelCopy`), classified, with its template.
    struct PreparedCapture: Sendable {
        let image: CGImage
        let bytes: Data
        let tone: GlyphTone
        let style: GlyphStyle
        let template: CGImage?
    }

    /// The lookups `loadCached` / `preloadCached` need for `items` (items without a capture yet, with a stable and
    /// unique identity, not already known to be missing from the disk cache). Prunes the disk cache once.
    private func cacheRequests(_ items: [MenuBarItem]) -> [CacheRequest] {
        guard diskCache != nil else { return [] }
        pruneIfDue()
        let appearance = Self.currentAppearance
        let scale = menuBarScale
        let counts = Dictionary(items.map { ($0.identity, 1) }, uniquingKeysWith: +)
        return items.compactMap { item in
            guard images[item.windowID] == nil, item.bundleID != nil, counts[item.identity] == 1 else { return nil }
            let key = ItemImageCacheKey(identity: item.identity, appearance: appearance, scale: Int(scale))
            guard !diskMisses.contains(key) else { return nil }
            return CacheRequest(windowID: item.windowID, key: key,
                                pixelWidth: Int((item.frame.width * scale).rounded()),
                                pixelHeight: Int((item.frame.height * scale).rounded()), scale: scale)
        }
    }

    /// Reads and prepares one entry (callable off the main actor); nil when it is missing or its pixel size doesn't
    /// match the item's current frame.
    nonisolated private static func prepare(_ request: CacheRequest, from diskCache: ItemImageDiskCache)
        -> PreparedCapture? {
        guard let cached = diskCache.load(request.key),
              abs(cached.image.width - request.pixelWidth) <= 1, abs(cached.image.height - request.pixelHeight) <= 1,
              let copy = PixelCopy(cached.image)
        else { return nil }
        var template: CGImage?
        if case .monochrome(let tone) = cached.style { template = GlyphMask.make(from: copy.image, tone: tone) }
        return PreparedCapture(image: copy.image, bytes: copy.bytes, tone: cached.tone, style: cached.style,
                               template: template)
    }

    private func apply(_ prepared: [PreparedCapture?], for requests: [CacheRequest], from diskCache: ItemImageDiskCache,
                       generation startGeneration: Int) {
        guard generation == startGeneration else { return }
        var loaded: [ItemImageCacheKey] = []
        for (request, capture) in zip(requests, prepared) {
            guard let capture else {
                diskMisses.insert(request.key)
                continue
            }
            // Captured while the entry was loading: keep the fresh capture.
            guard images[request.windowID] == nil else { continue }
            store(capture.image, tone: capture.tone, style: capture.style, template: capture.template,
                  scale: request.scale, for: request.windowID)
            pixels[request.windowID] = capture.bytes
            loaded.append(request.key)
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
    /// kept. New captures are also written to the disk cache (overwriting old entries), each item at most once per
    /// `diskWriteInterval` (see `flushDiskCache()`).
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
        var toSave: [(key: ItemImageCacheKey, value: DiskWrite)] = []
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
            if let write = diskWrites.offer(DiskWrite(image: copy.image, tone: tone, style: style), for: key, now: .now) {
                toSave.append((key, write))
            }
        }
        // Held-back captures of items that stopped changing are written once their interval has passed.
        toSave += diskWrites.takeDue(now: .now)
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
            Task.detached(priority: .utility) { Self.write(toSave, to: diskCache) }
        }
        pruneIfDue()
        return Set(fresh.keys)
    }

    /// Writes the held-back captures to the disk cache now (the Frost Bar closed, the layout editor stopped, Frost is
    /// quitting). `synchronously`: write before returning (when quitting); otherwise in the background.
    public func flushDiskCache(synchronously: Bool = false) {
        guard let diskCache else { return }
        let writes = diskWrites.takeAll(now: .now)
        guard !writes.isEmpty else { return }
        if synchronously {
            Self.write(writes, to: diskCache)
        } else {
            Task.detached(priority: .utility) { Self.write(writes, to: diskCache) }
        }
    }

    nonisolated private static func write(_ writes: [(key: ItemImageCacheKey, value: DiskWrite)],
                                          to diskCache: ItemImageDiskCache) {
        for (key, write) in writes {
            do {
                try diskCache.save(write.image, tone: write.tone, style: write.style, for: key)
            } catch {
                FrostLog.capture.error("could not write \(key.fileStem, privacy: .private) to the image cache: \(error, privacy: .public)")
            }
        }
    }

    private func pruneIfDue() {
        guard let diskCache, pruneSchedule.runIfDue(now: .now) else { return }
        Task.detached(priority: .utility) { diskCache.prune() }
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
            Dictionary(StatusWindowParser.windows(withIDs: ids)
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
        var template: CGImage?
        if case .monochrome(let tone) = style { template = GlyphMask.make(from: image, tone: tone) }
        store(image, tone: tone, style: style, template: template, scale: scale, for: id)
    }

    private func store(_ image: CGImage, tone: GlyphTone, style: GlyphStyle, template: CGImage?, scale: CGFloat,
                       for id: CGWindowID) {
        images[id] = image
        tones[id] = tone
        styles[id] = style
        sizes[id] = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        templates[id] = template
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
struct PixelCopy: Sendable {
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
