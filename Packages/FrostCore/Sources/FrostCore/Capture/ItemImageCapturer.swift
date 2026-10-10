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
    /// macOS 27: items whose crop was background only in the most recent capture (log only on change).
    @ObservationIgnored private var lastUndrawnCount = 0
    /// Number of items captured per window in the most recent `capture` (strip capture failed or the frame changed
    /// around the capture); for statistics.
    @ObservationIgnored public private(set) var lastPerWindowCount = 0
    /// Debug: log items whose frame is inconsistent during strip capture (`FROST_LIVE_REFRESH_TRACE=1`).
    @ObservationIgnored public var traceStripMismatches = false
    /// Display hosting the scanned menu bar (the active menu bar, `MenuBarItemScanner.menuBarDisplay`); strip capture
    /// and scale follow it. Injected by the app layer; defaults to the main display.
    @ObservationIgnored public var menuBarDisplayID: () -> CGDirectDisplayID = { CGMainDisplayID() }

    /// Which menu bar this is (`MenuBarBackend`). On macOS 27 there are no per-item windows to include in a strip
    /// filter and no window list to read frames from, so the strip is captured from the display and the glyphs are
    /// lifted out of it (`StripGlyphExtraction`). Injected by the app layer.
    @ObservationIgnored public var backend: MenuBarBackend = .windowList

    /// The items' frames right now, for the "did it move during the capture" check: the window list on macOS 26, the
    /// Accessibility scan on macOS 27 (where the window list has nothing to say). Injected by the app layer.
    @ObservationIgnored public var itemFrames: () -> [CGWindowID: CGRect] = { [:] }

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
    /// Captures taken with the previous appearance (see `appearanceDidChange`): still shown, but replaced by the disk
    /// cache entry for the new appearance or the next capture, and reported by `missing(_:)`.
    @ObservationIgnored private var stale: Set<CGWindowID> = []

    public init(diskCache: ItemImageDiskCache? = ItemImageDiskCache.defaultDirectory.map(ItemImageDiskCache.init)) {
        self.diskCache = diskCache
        // Glyph colors change with the appearance (light/dark): captures must be retaken.
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
        // KVO callbacks have no thread guarantee; hop back to the main actor.
            Task { @MainActor in self?.appearanceDidChange() }
        }
    }

    /// The appearance changed: captures in flight (old appearance) are discarded, but the existing images stay on
    /// screen until fresh ones arrive, so the Frost Bar and the layout editor never blank every tile or resize twice
    /// (monochrome glyphs are template-tinted in the Frost Bar anyway). They are marked stale: `loadCached` replaces
    /// them with the disk cache entries for the new appearance, and `missing` reports them so they are recaptured.
    public func appearanceDidChange() {
        generation += 1
        stale.formUnion(images.keys)
        pixels.removeAll()
        diskMisses.removeAll()
        capturesInvalidated()
    }

    /// Called when existing captures became invalid (`appearanceDidChange`), so work that stopped because every
    /// capture was current (the background capture of items behind the notch) can start again.
    @ObservationIgnored public var capturesInvalidated: () -> Void = {}

    /// Returns the items in `images` that have no current capture (none yet, or a stale one from the previous
    /// appearance), for the caller to capture. Fills from the disk cache first (see `loadCached(_:)`).
    public func missing(_ items: [MenuBarItem]) -> [MenuBarItem] {
        loadCached(items)
        return items.filter { images[$0.windowID] == nil || stale.contains($0.windowID) }
    }

    /// Fills in, from the disk cache, items in `items` that have no capture yet (entries for the current menu bar
    /// appearance and the scanned display's scale). Synchronous: the Frost Bar calls it right before showing the panel
    /// for anything `preloadCached(_:)` hasn't loaded yet.
    ///
    /// Skips: items with unknown ownership (unstable identity); items whose identity is duplicated within `items`
    /// (indistinguishable); entries whose height does not match the item's (another menu bar height). An entry of a
    /// different width (a text item whose content changed) is used anyway, drawn at its own width: an old picture of
    /// the item until a capture replaces it is better than a blank placeholder. Prunes entries not seen for 30 days in
    /// the background (at most once a day).
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
        /// Keys the entry may still be stored under (`ItemImageCacheKey.earlierKeys`): the first hit is moved to `key`.
        let earlierKeys: [ItemImageCacheKey]
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
        let counts = Dictionary(items.compactMap(\.identity).map { ($0, 1) }, uniquingKeysWith: +)
        return items.compactMap { item in
            guard images[item.windowID] == nil || stale.contains(item.windowID), let identity = item.identity,
                  counts[identity] == 1 else { return nil }
            let key = ItemImageCacheKey(identity: identity, appearance: appearance, scale: Int(scale))
            guard !diskMisses.contains(key) else { return nil }
            return CacheRequest(windowID: item.windowID, key: key, earlierKeys: key.earlierKeys(of: item),
                                pixelHeight: Int((item.frame.height * scale).rounded()), scale: scale)
        }
    }

    /// Reads and prepares one entry (callable off the main actor); nil when it is missing, its height doesn't match
    /// the item's, or it has no visible pixels.
    nonisolated private static func prepare(_ request: CacheRequest, from diskCache: ItemImageDiskCache)
        -> PreparedCapture? {
        guard let cached = diskCache.load(request.key, migratingFrom: request.earlierKeys),
              abs(cached.image.height - request.pixelHeight) <= 1,
              let copy = PixelCopy(cached.image), copy.hasVisiblePixels
        else { return nil }
        var template: CGImage?
        if case .monochrome(let tone) = cached.style { template = GlyphMask.make(from: copy.image, tone: tone) }
        return PreparedCapture(image: copy.image, bytes: copy.bytes, tone: cached.tone, style: cached.style,
                               template: template)
    }

    /// Copies and classifies a fresh capture (callable off the main actor); nil when it has no visible pixels (a
    /// window caught mid-move or not drawn yet: storing it would blank the tile). `unchanged` when its pixels equal
    /// `previous` (then it isn't classified).
    nonisolated private static func prepareFresh(_ image: CGImage, previous: Data?) -> FreshCapture? {
        guard let copy = PixelCopy(image), copy.hasVisiblePixels else { return nil }
        if copy.bytes == previous { return .unchanged }
        let style = GlyphStyle.of(copy.image)
        var template: CGImage?
        if case .monochrome(let tone) = style { template = GlyphMask.make(from: copy.image, tone: tone) }
        return .changed(PreparedCapture(image: copy.image, bytes: copy.bytes, tone: GlyphTone.of(copy.image),
                                        style: style, template: template))
    }

    enum FreshCapture: Sendable {
        case unchanged
        case changed(PreparedCapture)
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
            guard images[request.windowID] == nil || stale.contains(request.windowID) else { continue }
            store(capture.image, tone: capture.tone, style: capture.style, template: capture.template,
                  scale: request.scale, for: request.windowID)
            pixels[request.windowID] = capture.bytes
            stale.remove(request.windowID)
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
        await captureReporting(items).obtained
    }

    /// What one `captureReporting` call did with each item.
    public struct CaptureReport: Equatable, Sendable {
        /// Items a new capture was stored for (it differs from the previous one, or there was none).
        public var changed: Set<CGWindowID> = []
        /// Items whose new capture is pixel-identical to the stored one (left as is).
        public var unchanged: Set<CGWindowID> = []
        /// Items ScreenCaptureKit returned an image for (including blank ones that were discarded): what `capture`
        /// returns.
        public var obtained: Set<CGWindowID> = []
        /// The appearance changed meanwhile: the round's results were thrown away (nothing failed).
        public var discarded = false

        public init(changed: Set<CGWindowID> = [], unchanged: Set<CGWindowID> = [], obtained: Set<CGWindowID> = [],
                    discarded: Bool = false) {
            self.changed = changed
            self.unchanged = unchanged
            self.obtained = obtained
            self.discarded = discarded
        }

        /// Whether `id` was captured successfully in this round (changed or not). A failed or blank capture leaves the
        /// previous image in place, so the cache alone can't tell.
        public func succeeded(_ id: CGWindowID) -> Bool { changed.contains(id) || unchanged.contains(id) }
    }

    /// `capture`, reporting per item whether the round succeeded and whether the image changed.
    public func captureReporting(_ items: [MenuBarItem]) async -> CaptureReport {
        guard CGPreflightScreenCaptureAccess() else { return CaptureReport() }
        if backend == .accessibility { return await captureMenuBarStripReporting(items) }
        let startGeneration = generation
        let appearance = Self.currentAppearance
        let targets = items.filter(\.isOnScreen)
        guard let content = await contentCache.content(containing: Set(targets.map(\.windowID))) else {
            return CaptureReport()
        }
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
        guard generation == startGeneration else { return CaptureReport(discarded: true) }
        // Copy and classify off the main thread (a first round after opening the Frost Bar replaces every tile).
        let inputs = items.compactMap { item in
            fresh[item.windowID].map { image in
                (id: item.windowID, image: image, previous: images[item.windowID] == nil ? nil : pixels[item.windowID])
            }
        }
        let prepared = await Task.detached(priority: .userInitiated) {
            Dictionary(inputs.compactMap { input in
                Self.prepareFresh(input.image, previous: input.previous).map { (input.id, $0) }
            }, uniquingKeysWith: { a, _ in a })
        }.value
        guard generation == startGeneration else { return CaptureReport(discarded: true) }
        return finish(prepared, items: items, obtained: Set(fresh.keys), appearance: appearance, scale: scale)
    }

    /// Records what a capture round obtained: stores the changed images, holds back disk writes, prunes caches of
    /// windows that no longer exist. Shared by both backends.
    private func finish(_ prepared: [CGWindowID: FreshCapture], items: [MenuBarItem],
                        obtained: Set<CGWindowID>, appearance: MenuBarAppearance, scale: CGFloat) -> CaptureReport {
        var report = CaptureReport(obtained: obtained)
        var toSave: [(key: ItemImageCacheKey, value: DiskWrite)] = []
        let counts = Dictionary(items.compactMap(\.identity).map { ($0, 1) }, uniquingKeysWith: +)
        for item in items {
            guard let result = prepared[item.windowID] else {
                if obtained.contains(item.windowID) {
                    FrostLog.capture.notice("discarding a blank capture of item \(item.windowID)")
                }
                continue
            }
            // Pixel-identical to the existing capture: leave it as is.
            guard case .changed(let capture) = result else {
                report.unchanged.insert(item.windowID)
                continue
            }
            report.changed.insert(item.windowID)
            store(capture.image, tone: capture.tone, style: capture.style, template: capture.template, scale: scale,
                  for: item.windowID)
            pixels[item.windowID] = capture.bytes
            stale.remove(item.windowID)
            guard let identity = item.identity, counts[identity] == 1 else { continue }
            let key = ItemImageCacheKey(identity: identity, appearance: appearance, scale: Int(scale))
            diskMisses.remove(key)
            let write = DiskWrite(image: capture.image, tone: capture.tone, style: capture.style)
            if let write = diskWrites.offer(write, for: key, now: .now) {
                toSave.append((key, write))
            }
        }
        // Held-back captures of items that stopped changing are written once their interval has passed.
        toSave += diskWrites.takeDue(now: .now)
        // Prune by the items that still exist in the system (not by the given items), so capturing a subset does not
        // clear other items' caches. Do not assign when nothing changed (the assignment itself notifies observers and
        // makes Frost Bar redraw).
        //
        // On macOS 27 the window list is *empty* — there are no status windows at all — so pruning by it would drop
        // every image on every round, right after capturing it. There, the items that exist are the ones the
        // Accessibility scan reports.
        let existing: Set<CGWindowID> = backend == .accessibility
            ? Set(itemFrames().keys)
            : Set(StatusWindowParser.currentWindows().map(\.windowID))
        if images.keys.contains(where: { !existing.contains($0) }) {
            images = images.filter { existing.contains($0.key) }
            tones = tones.filter { images[$0.key] != nil }
            styles = styles.filter { images[$0.key] != nil }
            templates = templates.filter { images[$0.key] != nil }
            sizes = sizes.filter { images[$0.key] != nil }
            pixels = pixels.filter { images[$0.key] != nil }
            stale = stale.filter { images[$0] != nil }
        }
        if let diskCache, !toSave.isEmpty {
            Task.detached(priority: .utility) { Self.write(toSave, to: diskCache) }
        }
        pruneIfDue()
        return report
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
    /// macOS 27: one capture of the menu bar strip, then each item's glyph lifted out of it.
    ///
    /// Nothing here can be addressed per item: there are no status item windows to include in a filter, and the
    /// system reports a pushed-out item at the frame it had before it left. So the strip is captured from the display
    /// and cropped by the frames the caller passes (read from Accessibility), and a crop that turns out to be
    /// background only is *not* used — that item simply has no image and keeps its app icon, rather than showing a
    /// neighbour's icon or a piece of wallpaper.
    private func captureMenuBarStripReporting(_ items: [MenuBarItem]) async -> CaptureReport {
        let startGeneration = generation
        let targets = items.filter(\.isOnScreen)
        guard !targets.isEmpty,
              let content = await contentCache.content(),
              let display = content.displays.first(where: { $0.displayID == menuBarDisplayID() })
                ?? content.displays.first
        else { return CaptureReport() }
        let scale = menuBarScale
        let captured = await captureMenuBarStrip(targets, display: display, scale: scale)
        guard generation == startGeneration else { return CaptureReport(discarded: true) }
        let inputs = items.compactMap { item in
            captured[item.windowID].map { image in
                (id: item.windowID, image: image, previous: images[item.windowID] == nil ? nil : pixels[item.windowID])
            }
        }
        let prepared = await Task.detached(priority: .userInitiated) {
            Dictionary(inputs.compactMap { input in
                Self.prepareFresh(input.image, previous: input.previous).map { (input.id, $0) }
            }, uniquingKeysWith: { a, _ in a })
        }.value
        guard generation == startGeneration else { return CaptureReport(discarded: true) }
        return finish(prepared, items: items, obtained: Set(captured.keys), appearance: Self.currentAppearance,
                      scale: menuBarScale)
    }

    private func captureMenuBarStrip(_ targets: [MenuBarItem], display: SCDisplay, scale: CGFloat)
        async -> [CGWindowID: CGImage] {
        let bounds = CGDisplayBounds(menuBarDisplayID())
        guard let rect = StripCrop.stripRect(covering: targets.map(\.frame), display: bounds) else { return [:] }
        let before = itemFrames()
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = Int((rect.width * scale).rounded())
        config.height = Int((rect.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let strip: CGImage
        do {
            strip = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            FrostLog.capture.error("menu bar strip capture failed: \(error, privacy: .public)")
            return [:]
        }
        let after = itemFrames()
        let origin = CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY)
        let size = CGSize(width: strip.width, height: strip.height)
        var result: [CGWindowID: CGImage] = [:]
        var undrawn = 0
        let total = targets.count
        for item in targets where (before[item.windowID] ?? item.frame) == item.frame
            && (after[item.windowID] ?? item.frame) == item.frame {
            guard let pixels = StripCrop.pixelRect(of: item.frame, stripOrigin: origin, scale: scale, imageSize: size),
                  let crop = strip.cropping(to: pixels), let copy = PixelCopy(crop) else { continue }
            let buffer = StripGlyphExtraction.Buffer(bytes: [UInt8](copy.bytes), width: crop.width, height: crop.height)
            guard let extracted = StripGlyphExtraction.extract(buffer),
                  StripGlyphExtraction.isItemDrawn(extracted),
                  let image = extracted.buffer.cgImage() else {
                undrawn += 1
                continue
            }
            result[item.windowID] = image
        }
        if undrawn > 0, undrawn != lastUndrawnCount {
            lastUndrawnCount = undrawn
            FrostLog.capture.notice("""
                \(undrawn, privacy: .public) of \(total, privacy: .public) item(s) the menu bar does not draw at \
                their reported frame; they keep their app icon
                """)
        } else if undrawn == 0 {
            lastUndrawnCount = 0
        }
        return result
    }

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
    static var currentAppearance: MenuBarAppearance {
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    /// Scale of the display hosting the scanned menu bar (not NSScreen.main: that is the screen with the
    /// key window).
    var menuBarScale: CGFloat {
        let displayID = menuBarDisplayID()
        return NSScreen.screens.first { $0.displayID == displayID }?.backingScaleFactor ?? 2
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

    /// Whether any pixel is not fully transparent.
    var hasVisiblePixels: Bool { Self.hasVisiblePixels(bytes) }

    /// `bytes` are 32-bit little-endian premultiplied ARGB pixels (BGRA in memory, alpha in each pixel's last byte).
    static func hasVisiblePixels(_ bytes: Data) -> Bool {
        bytes.withUnsafeBytes { raw in
            var index = 3
            while index < raw.count {
                if raw[index] != 0 { return true }
                index += 4
            }
            return false
        }
    }
}
