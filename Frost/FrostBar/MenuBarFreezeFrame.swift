import AppKit
import FrostCore
import ScreenCaptureKit

/// Freeze frame: while the menu bar is temporarily expanded to capture missing screenshots, a capture of the menu bar
/// "as it is now" covers it, so the user never sees the hidden icons expand and collapse.
///
/// ScreenCaptureKit can't capture off-screen windows (-3811), so hidden items pushed off screen can only be captured
/// after a temporary expansion. Flow (see `FrostBarController`): `show()` captures the menu bar strip at the top of every
/// screen that has one -> puts it in a borderless, non-activating, click-through window exactly over the menu bar ->
/// expand -> capture per window (`SCContentFilter(desktopIndependentWindow:)` takes only that window's own content,
/// unaffected by occlusion) -> collapse and wait to settle -> `remove()`.
///
/// - Level `statusBar + 1` (26): above status item windows (layer 25), below menus (`popUpMenu`, 101). Not 25: the
///   scanner treats every layer-25 window on the menu bar row as a status item. The overlay covers only the menu bar
///   strip; the Frost Bar panel (actually at `.floating`, since `isFloatingPanel` resets `level`) has its visible
///   content 6 pt below the menu bar, outside the strip, so it isn't covered (its shadow is; see below).
///   The panel isn't raised above the overlay: when its content size changes (e.g. a capture arrives) there is one
///   misplaced frame where content pokes into the menu bar strip (observed in the VM, pre-existing behavior). At
///   layer 3 that frame draws below the status items; raised, it would draw above them and be more noticeable.
/// - The capture **includes** Frost's own windows: the Frost Bar panel's (layer 3) shadow reaches into the menu bar
///   strip (the panel's top edge is 6 pt below the menu bar), and the freeze frame (layer 26) sits above the panel. If
///   the capture excluded the panel, the freeze frame would lack that shadow, so the menu bar above the panel would
///   brighten every time the freeze frame appears and darken when it's removed. Invisible on a black wallpaper, but a
///   once-a-second flicker on a colorful one (user report on a notched display with a red-orange gradient wallpaper;
///   see `docs/testing-vm.md` "Verification techniques" to reproduce in the VM). The previous round's freeze frame is
///   long gone by capture time, so it never ends up in the capture.
/// - The capture uses the display's own color space (`displayIntent = .local`, SDR; the capture carries the display's
///   ICC profile, and the overlay window defaults to the screen's color space), so no color conversion happens. The
///   region is rounded to device pixels, captured at native pixels for the screen's scale, and shown 1:1 (nearest
///   neighbor, no scaling). The notch area is covered too (physically invisible, so harmless); the capture is the
///   actual picture at that moment, so light / dark menu bars and wallpaper tinting are preserved.
///   Measured on the VM framebuffer (VNC): on a gradient wallpaper the freeze frame still differs from the real menu
///   bar by <= 2 levels (about 64% of pixels off by 1-2 levels, along the wallpaper gradient's banding edges).
///   ScreenCaptureKit rounds differently from the framebuffer when re-rendering the desktop; changing the capture API /
///   pixel format, re-tagging the color space, or setting `window.colorSpace` gives identical results. Not visible.
/// - Only the part of the menu bar that changes on expansion is covered (`LiveRefreshPolicy.changingRegion`): on each
///   screen, only the area left of that screen's Frost icon (real window or replica); the icon and everything to its
///   right (clock, Control Center) stay live. While the Frost Bar is open it refreshes every second with the freeze
///   frame on screen about half the time, so covering the whole bar would make the clock and other items look stuck.
/// - If capturing any screen fails, `show()` returns nil and the caller doesn't expand (better to show app icons than
///   to flicker).
/// - Shown for at most `maximumDuration`, then removed automatically (a safety net; normally `remove()` runs in a
///   `defer`).
@MainActor
final class MenuBarFreezeFrame {
    static let level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    /// Safety net: a normal round takes ~0.2 s; collapsing occasionally takes ~0.5 s to apply. A round keeps waiting
    /// for the collapse to be confirmed until shortly before this limit (`FrostBarController.restoreBudget`).
    static let maximumDuration: Duration = .seconds(3)

    /// Log a capture / screen color space mismatch only once (rounds run every second).
    private static var loggedColourSpaceMismatch = false

    private var windows: [NSWindow]
    private var timeout: Task<Void, Never>?

    private init(windows: [NSWindow]) {
        self.windows = windows
    }

    var isShown: Bool { !windows.isEmpty }

    /// Captures the menu bar and shows the overlay, returning once it is actually on screen. On failure shows nothing
    /// and returns nil. `iconFrames`: the Frost icon's frame on each display (AppKit global coordinates; the real window
    /// plus replicas on other displays); each menu bar strip covers only the area left of its own icon.
    /// `managedDisplayID`: the display of the scanned menu bar (uses `menuBarFallbackHeight` when it auto-hides).
    static func show(menuBarFallbackHeight: CGFloat, iconFrames: [CGRect], managedDisplayID: CGDirectDisplayID,
                     contentCache: ShareableContentCache) async -> MenuBarFreezeFrame? {
        let strips = menuBarStrips(fallbackHeight: menuBarFallbackHeight, iconFrames: iconFrames,
                                   managedDisplayID: managedDisplayID)
        guard !strips.isEmpty else { return nil }
        guard let content = await contentCache.content() else {
            FrostLog.freezeFrame.error("no shareable content")
            return nil
        }
        var captured: [(Strip, CGImage)] = []
        for strip in strips {
            guard let display = content.displays.first(where: { $0.displayID == strip.displayID }) else {
                FrostLog.freezeFrame.error("display \(strip.displayID) not found")
                contentCache.invalidate()
                return nil
            }
            // Include Frost's windows (the panel's shadow reaching into the menu bar must be in the freeze frame; see
            // the type's documentation).
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCScreenshotConfiguration()
            // sourceRect: the display's own logical coordinates (points, top-left origin).
            config.sourceRect = CGRect(x: strip.frame.minX - strip.screenFrame.minX, y: 0,
                                       width: strip.frame.width, height: strip.frame.height)
            config.width = Int((strip.frame.width * strip.scale).rounded())
            config.height = Int((strip.frame.height * strip.scale).rounded())
            config.showsCursor = false
            // Shadows must be included explicitly: they are ignored by default, but the menu bar is transparent and the
            // shadow of a window below darkens its bottom edge. Without it the freeze frame is brighter than the real
            // menu bar and flickers on every show / remove (seen on real hardware; not reproducible in the VM, where
            // no window touches the menu bar).
            config.ignoreShadows = false
            config.displayIntent = .local
            config.dynamicRange = .sdr
            do {
                let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config)
                guard let image = output.sdrImage else {
                    FrostLog.freezeFrame.error("empty screenshot of display \(strip.displayID)")
                    return nil
                }
                if !loggedColourSpaceMismatch, let screenSpace = strip.colorSpace?.cgColorSpace,
                   let imageSpace = image.colorSpace,
                   imageSpace.copyICCData() as Data? != screenSpace.copyICCData() as Data? {
                    // Identical ICC data in the VM; if they differ on real hardware, the freeze frame's colors may
                    // drift from the menu bar, so log it once for diagnosis.
                    loggedColourSpaceMismatch = true
                    FrostLog.freezeFrame.notice("""
                        screenshot colour space \(String(describing: imageSpace), privacy: .public) \
                        differs from the screen's \(String(describing: screenSpace), privacy: .public)
                        """)
                }
                captured.append((strip, image))
            } catch {
                FrostLog.freezeFrame.error("screenshot of display \(strip.displayID) failed (\(error, privacy: .public))")
                return nil
            }
        }
        let frame = MenuBarFreezeFrame(windows: captured.map { makeWindow(strip: $0.0, image: $0.1) })
        for window in frame.windows { window.orderFrontRegardless() }
        frame.timeout = Task { [weak frame] in
            try? await Task.sleep(for: maximumDuration)
            guard let frame, frame.isShown, !Task.isCancelled else { return }
            FrostLog.freezeFrame.error("still shown after \(maximumDuration, privacy: .public); removing it")
            frame.remove()
        }
        await frame.waitUntilOnScreen()
        return frame
    }

    /// Pays ScreenCaptureKit's one-time setup costs ahead of the first live refresh round (called by the Frost Bar's
    /// launch warm-up): fetches the shareable content and takes one tiny screenshot of the managed menu bar, the same
    /// kind of capture `show` takes, without showing anything. Measured in the VM, the first capture otherwise spends
    /// tens of ms on the main thread setting up (e.g. a media clock) in the middle of the first round.
    static func warmUp(managedDisplayID: CGDirectDisplayID, contentCache: ShareableContentCache) async {
        guard let content = await contentCache.content(),
              let display = content.displays.first(where: { $0.displayID == managedDisplayID }) else { return }
        let config = SCScreenshotConfiguration()
        config.sourceRect = CGRect(x: 0, y: 0, width: 2, height: 2)
        config.width = 2
        config.height = 2
        config.showsCursor = false
        config.displayIntent = .local
        config.dynamicRange = .sdr
        _ = try? await SCScreenshotManager.captureScreenshot(
            contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
    }

    /// Removes the overlay windows (idempotent).
    func remove() {
        timeout?.cancel()
        timeout = nil
        for window in windows { window.orderOut(nil) }
        windows = []
    }

    /// After collapsing, the menu bar takes a frame or two to redraw; wait that long before removing the overlay so the
    /// last expanded frame never shows. Based on the slowest frame interval (two frames at ProMotion's idle 24 Hz
    /// ~= 83 ms); still 50 ms on a 60 Hz screen.
    static var settleDelay: Duration {
        let frame = NSScreen.screens.map(\.maximumRefreshInterval).max() ?? (1.0 / 60.0)
        return .milliseconds(max(50, Int((frame * 2000).rounded(.up)) + 10))
    }

    // MARK: - Private

    struct Strip {
        var displayID: CGDirectDisplayID
        /// Region to cover, in AppKit global coordinates (bottom-left origin); used to place the window.
        var frame: CGRect
        /// The screen's frame (AppKit global coordinates); used to compute the capture's sourceRect.
        var screenFrame: CGRect
        var scale: CGFloat
        var colorSpace: NSColorSpace?
    }

    /// Menu bar strips to cover: on every screen showing a menu bar (`frame.maxY - visibleFrame.maxY > 0`), the part
    /// that changes on expansion (`LiveRefreshPolicy.changingRegion`). Every screen's menu bar has Frost's status items
    /// (replicas on other screens), so all of them change. When the managed one's menu bar (`managedDisplayID`, where
    /// the active menu bar is) auto-hides its height is 0, so `fallbackHeight` (the Frost icon window's height) is used.
    /// Returns whole menu bars when `iconFrames` is empty.
    static func menuBarStrips(fallbackHeight: CGFloat, iconFrames: [CGRect],
                              managedDisplayID: CGDirectDisplayID) -> [Strip] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let id = number.uint32Value
            var height = screen.frame.maxY - screen.visibleFrame.maxY
            if height <= 0, id == managedDisplayID { height = fallbackHeight }
            guard height > 0 else { return nil }
            let full = CGRect(x: screen.frame.minX, y: screen.frame.maxY - height,
                              width: screen.frame.width, height: height)
            let scale = screen.backingScaleFactor
            let region = LiveRefreshPolicy.pixelAligned(LiveRefreshPolicy.changingRegion(of: full, iconFrames: iconFrames),
                                                        scale: scale)
            guard region.width >= 1 else { return nil }
            return Strip(displayID: id, frame: region, screenFrame: screen.frame, scale: scale,
                         colorSpace: screen.colorSpace)
        }
    }

    private static func makeWindow(strip: Strip, image: CGImage) -> NSWindow {
        let window = FreezeFrameWindow(contentRect: strip.frame, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
        window.level = level
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.hasShadow = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.canHide = false
        window.setAccessibilityElement(false)
        // Leave `colorSpace` at its default (the screen's color space, same as the capture's profile); setting it
        // explicitly has no effect (verified in the VM).
        let view = NSView(frame: NSRect(origin: .zero, size: strip.frame.size))
        view.wantsLayer = true
        view.layer?.contents = image
        view.layer?.contentsScale = strip.scale
        view.layer?.contentsGravity = .resize
        // Already 1:1 (the region is rounded to device pixels); avoid interpolation blur on any rounding difference.
        view.layer?.magnificationFilter = .nearest
        view.layer?.minificationFilter = .nearest
        window.contentView = view
        window.setFrame(strip.frame, display: true)
        return window
    }

    /// Waits until the window server reports every overlay window on screen (up to 150 ms), then one more frame so they
    /// are actually composited.
    private func waitUntilOnScreen() async {
        CATransaction.flush()
        let ids = windows.map { CGWindowID($0.windowNumber) }
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(150)
        while clock.now < deadline {
            let onScreen = ids.allSatisfy { id in
                let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]]
                return info?.first?[kCGWindowIsOnscreen as String] as? Bool == true
            }
            if onScreen { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: Self.presentationDelay(forMaximumRefreshInterval: windows.compactMap { $0.screen?.maximumRefreshInterval }.max()))
    }

    /// Wait between the overlay reaching the screen and expanding: at least the slowest frame interval plus margin.
    /// Idle ProMotion screens drop to 24 Hz (`maximumRefreshInterval` ~= 41.7 ms), so a fixed 34 ms could expand before
    /// the overlay is composited and flash the hidden icons for a frame.
    static func presentationDelay(forMaximumRefreshInterval interval: TimeInterval?) -> Duration {
        let frame = interval ?? (1.0 / 60.0)
        return .milliseconds(max(34, Int((frame * 1000).rounded(.up)) + 10))
    }
}

/// Overlay window: never key / main, and not pushed below the menu bar by AppKit.
private final class FreezeFrameWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
