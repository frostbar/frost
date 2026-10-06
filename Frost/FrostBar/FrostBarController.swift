import AppKit
import FrostCore
import SwiftUI

enum FrostBarError: Error {
    /// The layout editor is open: the menu bar is in editing mode, so no click forwarding.
    case editing
    /// Frost's own control items can't be found.
    case controlsMissing
    case itemNotFound
    /// The item is still off screen after moving it out (e.g. the Visible section is full, or it's under the notch):
    /// a click would open in the wrong place.
    case notOnScreen
}

/// Frost Bar: a glass panel dropping down from the Frost icon that shows the Hidden section's icons in a grid (plus the
/// Always Hidden section below it with ⌥). Clicking an icon temporarily moves the original into the Visible section,
/// clicks it (a right / Control click forwards a right click, a ⌥-click a left click with Option), waits for its menu /
/// popover to close, lingers while the user is still using the item in the menu bar (`ForwardLinger`), then moves it
/// back.
///
/// The panel is only used while the menu bar is collapsed: then the order of the pushed-out items is reliable (on a
/// crowded notched display, expanded items that don't fit are stuffed under the notch, where positions are unreliable
/// and moves can't be verified). If not collapsed when opening the panel or forwarding a click, collapse first (and
/// don't re-expand afterwards).
///
/// Live refresh: hidden items can't be captured while collapsed, so the panel first shows cached screenshots, then
/// every second (start to start, `LiveRefreshPolicy`) expands temporarily under a freeze frame, captures, and
/// collapses, keeping dynamic icons (temperatures, timers, ...) current. Each round is a move transaction serialized
/// with click forwarding (a click first waits for the round to collapse again). When the panel closes the loop stops
/// at once; a round in progress still collapses and removes its freeze frame.
///
/// Files: this one opens, closes, warms up and positions the panel; `FrostBarController+LiveRefresh.swift` has the
/// live refresh loop, `FrostBarController+Forwarding.swift` click forwarding, the linger and moving items back,
/// `FrostBarController+ObscuredCapture.swift` the background capture of items behind the notch (while the panel is
/// closed).
@MainActor
final class FrostBarController {
    let model: FrostBarModel

    let app: AppModel
    var panel: FrostBarPanel?
    private var hostingView: FrostBarHostingView?

    private(set) var isOpen = false
    private var monitors = EventMonitors()
    private var observers: [NSObjectProtocol] = []
    private var isPollingPermissions = false
    /// Incremented on every presentation; a leftover observation callback from an earlier presentation sees the
    /// mismatch and doesn't re-register (so repeated opens don't stack observation chains).
    private var presentation = 0
    #if DEBUG
    private var openCount = 0
    #endif

    private var openTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    var captureTask: Task<Void, Never>?
    var activationTask: Task<Void, Never>?
    var refreshTask: Task<Void, Never>?
    /// A delayed retry scheduled after a failed move-back (runs in its own move transaction).
    var restoreRetryTask: Task<Void, Never>?
    static let restoreRetryDelay: Duration = .milliseconds(1500)

    /// The background capture of items behind the notch (`FrostBarController+ObscuredCapture.swift`): the loop that
    /// decides when to run, the operation in progress (a task that doesn't inherit cancellation: it always moves the
    /// item back), a click its freeze frame took, and the last reason it waited (logged once per change).
    var obscuredLoop: Task<Void, Never>?
    var obscuredCaptureTask: Task<Void, Never>?
    var interceptedClick: InterceptedClick?
    var lastObscuredSkip: ObscuredCapturePolicy.SkipReason?

    /// Items still uncapturable after a temporary expansion (under the notch) keep their disk-cached screenshot or app
    /// icon. When every item is like that, stop expanding (retry only after a layout or display configuration change,
    /// or a manual refresh); see `LiveRefreshPolicy.Conditions.hasCapturableItems`.
    var retryPolicy = CaptureRetryPolicy()

    /// The live refresh loop (runs while the panel is open, cancelled on close; a round in progress lives in
    /// `captureTask` and isn't interrupted by the cancellation).
    var liveTask: Task<Void, Never>?
    var lastCycleStart: ContinuousClock.Instant?
    var lastCycleEnd: ContinuousClock.Instant?
    /// When the panel was presented this time: the first round waits for the appearance animation to finish
    /// (`LiveRefreshPolicy.appearanceDuration`).
    var presentedAt: ContinuousClock.Instant?
    var liveStats = LiveRefreshStats()
    /// The last forwarded click's non-menu presentation may stay on screen after the wait times out / gives up; live
    /// refresh pauses while it's still there.
    var lingeringPresentation: Set<CGWindowID> = []
    /// Milestones of the click forward in progress, logged once the item has been clicked.
    var forwardTrace: ForwardTrace?
    /// The tile under the pointer (right clicks go to it, see `FrostBarPanel.onSecondaryClick`).
    private var hoveredTile: CGWindowID?
    /// Set when the item of a finished click forward must stop lingering in the Visible section (the Frost Bar
    /// reopens); quitting cancels the forward instead.
    var endLingerRequested = false
    /// Environment variable `FROST_LIVE_REFRESH_TRACE=1` (Debug builds, VM measurements only): log timings for every
    /// round, and items whose frame changed around a strip capture (`ItemImageCapturer.traceStripMismatches`).
    #if DEBUG
    static let traceCycles = ProcessInfo.processInfo.environment["FROST_LIVE_REFRESH_TRACE"] == "1"
    #else
    static let traceCycles = false
    #endif

    init(app: AppModel) {
        self.app = app
        model = FrostBarModel(app: app)

        let workspace = NSWorkspace.shared.notificationCenter
        app.capturer.traceStripMismatches = Self.traceCycles
        app.mover.milestone = { [weak self] label, instant in self?.forwardTrace?.mark(label, at: instant) }
        app.obscuredItemsChanged = { [weak self] in self?.scheduleObscuredCapture() }
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(animated: false, reason: "active Space changed") }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.app.capturer.contentCache.invalidate()
                self?.close(animated: false, reason: "screen parameters changed")
            }
        })
        // Displays asleep, screen locked, another user's session: nobody can see the panel, so close it (which stops
        // live refresh: no more temporary expansions and captures). The user reopens it when back.
        observers.append(NotificationCenter.default.addObserver(
            forName: UserPresenceMonitor.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.app.presence.isAway, self.isOpen else { return }
                self.close(animated: false, reason: "user away")
            }
        })
    }

    // MARK: - Open / close

    /// The Frost icon was clicked (display mode is Frost Bar). While the panel is open, a plain click always closes
    /// it (one click, whatever the ⌥ state it was opened with); a ⌥-click shows / hides the Always Hidden section
    /// instead (a short fade and height change, see `FrostBarContent`). While the panel is still opening (waiting for a
    /// lingering item to move back) or has only just appeared, a click doesn't close it (`FrostBarIconClick`).
    func toggle(showAlwaysHidden: Bool) {
        let phase: FrostBarIconClick.Phase = !isOpen ? .closed : shownAt.map { .presented(at: $0) } ?? .opening
        switch FrostBarIconClick.decide(phase: phase, option: showAlwaysHidden,
                                        showingAlwaysHidden: model.showAlwaysHidden, now: .now) {
        case .open(let showAlwaysHidden):
            open(showAlwaysHidden: showAlwaysHidden)
        case .close:
            close(reason: "Frost icon clicked")
        case .keepOpening(let showAlwaysHidden):
            FrostLog.frostBar.notice("Frost icon clicked while the Frost Bar is opening; keeping it open")
            guard showAlwaysHidden == true, !model.showAlwaysHidden else { return }
            if shownAt == nil {
                // Not on screen yet: present with the section (live refresh starts once presented).
                model.showAlwaysHidden = true
            } else {
                setAlwaysHidden(true)
            }
        case .setAlwaysHidden(let show):
            setAlwaysHidden(show)
        }
    }

    /// Shows / hides the Always Hidden section of the open panel.
    private func setAlwaysHidden(_ show: Bool) {
        sectionTask?.cancel()
        if show {
            model.isAlwaysHiddenFading = false
            withAnimation(FrostBarMetrics.sectionAnimation) { model.showAlwaysHidden = true }
            // Refresh the newly shown section right away (don't wait for the next cycle).
            restartLiveRefresh(immediately: true)
            return
        }
        // Fade the section out first, then shrink.
        withAnimation(.easeIn(duration: Self.sectionFadeOut)) { model.isAlwaysHiddenFading = true }
        sectionTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Self.sectionFadeOut)) } catch { return }
            guard let self, self.isOpen else { return }
            withAnimation(FrostBarMetrics.sectionAnimation) { self.model.showAlwaysHidden = false }
            self.model.isAlwaysHiddenFading = false
        }
    }

    private var sectionTask: Task<Void, Never>?
    /// When the current `open` was requested (for the "presented after" log line).
    private var openRequestedAt: ContinuousClock.Instant?
    /// When the panel of the current open went on screen (nil: closed, or still opening).
    private var shownAt: ContinuousClock.Instant?
    /// The Frost icon's predicted right edge (x, the same in CG and AppKit) while it still slides into place after a
    /// lingering item moved back for this open; the panel is anchored there until the slide is over.
    var returnAnchorMaxX: CGFloat?
    private static let sectionFadeOut: TimeInterval = 0.1

    func open(showAlwaysHidden: Bool) {
        guard !isOpen, !app.presence.isAway else { return }
        isOpen = true
        // A previous forward's item may be lingering in the Visible section: move it back now.
        endLingerRequested = true
        hideTask?.cancel()
        sectionTask?.cancel()
        model.showAlwaysHidden = showAlwaysHidden
        model.isAlwaysHiddenFading = false
        model.beginSession()
        liveStats = LiveRefreshStats()
        #if DEBUG
        openCount += 1
        if let screen = app.sections.iconWindow?.screen ?? NSScreen.main {
            FrameProbe.mark("frostbar-open-\(openCount)", on: screen, duration: .milliseconds(1500))
        }
        #endif
        openRequestedAt = .now
        openTask = Task { [weak self] in
            // The previous click forward hasn't finished (e.g. its menu is still open, or it's moving back); wait for
            // it so the layout is final.
            if let activation = self?.activationTask {
                FrostLog.frostBar.notice("Frost Bar opening: waiting for the click forward in progress")
                await activation.value
            }
            // A background capture of an item behind the notch is moving it (the click that opens the panel was taken
            // by its freeze frame and replayed, or the panel opened another way): wait until it's back in its slot.
            if let capture = self?.obscuredCaptureTask {
                FrostLog.frostBar.notice("Frost Bar opening: waiting for the background capture in progress")
                await capture.value
            }
            await self?.flushRestoreRetry()
            guard let self, self.isOpen, !Task.isCancelled else { return }
            await self.prepareLayout()
            guard self.isOpen, !Task.isCancelled else { return }
            // The memory cache is empty after a relaunch: the warm-up has usually loaded the disk cache in the
            // background already (`warmUp`); load whatever it hasn't so the panel shows it as soon as it appears.
            if self.app.permissions.canCaptureImages { self.app.capturer.loadCached(self.requestedItems) }
            #if DEBUG
            FrameProbe.note("cached(images=\(self.app.capturer.images.count))")
            #endif
            self.present()
            if self.returnAnchorMaxX != nil {
                // Presented while the icons still slide after the move back: wait for them to settle, then anchor to
                // the icon's real frame, before live refresh may freeze the menu bar.
                await self.app.sections.waitForSettle()
                self.returnAnchorMaxX = nil
                guard self.isOpen, !Task.isCancelled else { return }
                self.reposition(allowShrink: false)
            }
            // Show cached screenshots first, then start live refresh (the first round runs after the panel's
            // appearance animation, so the freeze frame captures the panel shadow in its final state).
            self.restartLiveRefresh(immediately: true)
        }
    }

    /// `reason` is logged (diagnosing an unexpected close on a real Mac needs it).
    func close(animated: Bool = true, reason: StaticString) {
        guard isOpen else { return }
        let shown = shownAt.map { "shown for \(LiveRefreshStats.Timing.ms(.now - $0))" } ?? "not shown yet"
        FrostLog.frostBar.notice("""
            Frost Bar closed (\(String(describing: reason), privacy: .public)); panel \(shown, privacy: .public)
            """)
        isOpen = false
        shownAt = nil
        returnAnchorMaxX = nil
        openTask?.cancel()
        stopLiveRefresh()
        // Live refresh held back disk cache writes of changing icons (at most one per item per minute): write the
        // newest captures now.
        app.capturer.flushDiskCache()
        removeMonitors()
        if isPollingPermissions {
            isPollingPermissions = false
            app.permissions.stopPolling()
        }
        guard let panel, panel.isVisible else { return }
        withAnimation(.easeIn(duration: 0.14)) { model.isPresented = false }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            if animated {
                do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            }
            guard let self, !self.isOpen else { return }
            panel.orderOut(nil)
        }
    }

    /// Refreshes permissions, collapses the menu bar (if not collapsed), then rescans.
    private func prepareLayout() async {
        app.permissions.refresh()
        let sections = app.sections
        if sections.state != .collapsed, !sections.isEditing, !app.mover.isBusy {
            sections.setState(.collapsed)
            await sections.waitForSettle()
        }
        app.scanner.rescan()
    }

    private func present() {
        let panel = panel ?? makePanel()
        endPrerender()
        if !isPollingPermissions {
            isPollingPermissions = true
            app.permissions.startPolling()
        }
        hideTask?.cancel()
        model.isPresented = false
        reposition()
        panel.makeKeyAndOrderFront(nil)
        shownAt = .now
        #if DEBUG
        FrameProbe.note("ordered")
        #endif
        if let requested = openRequestedAt {
            let key = panel.isKeyWindow ? "key" : "not key"
            FrostLog.frostBar.notice("""
                Frost Bar presented \(LiveRefreshStats.Timing.ms(.now - requested), privacy: .public) after the \
                click (\(key, privacy: .public))
                """)
        }
        presentedAt = .now
        installMonitors()
        presentation += 1
        trackContentSize(presentation)
        // Switch to presented on the next run loop turn so the appearance animation starts from the initial state.
        Task { @MainActor [weak self] in
            guard let self, self.isOpen else { return }
            #if DEBUG
            FrameProbe.note("animate")
            #endif
            // The first live refresh round waits for the animation measured from here, when it really starts.
            self.presentedAt = .now
            withAnimation(.easeOut(duration: 0.18)) { self.model.isPresented = true }
        }
    }

    private func makePanel() -> FrostBarPanel {
        let panel = FrostBarPanel()
        let actions = FrostBarActions(
            activate: { [weak self] item, click in self?.activate(item.windowID, click: click) },
            hover: { [weak self] id in self?.hoveredTile = id },
            refresh: { [weak self] in self?.refresh() },
            grantAccessibility: { [weak self] in
                self?.close(animated: false, reason: "granting Accessibility")
                self?.app.permissions.requestAccessibility()
            },
            grantScreenRecording: { [weak self] in
                self?.close(animated: false, reason: "granting Screen Recording")
                self?.app.permissions.requestScreenRecording()
            },
            relaunch: { AppRelauncher.relaunch() },
            openSettings: { [weak self] in
                self?.close(animated: false, reason: "settings opened")
                self?.app.openSettings()
            },
            dismissScreenRecordingHint: { [weak self] in
                withAnimation(.snappy) { self?.app.preferences.screenRecordingHintDismissed = true }
            })
        let hostingView = FrostBarHostingView(rootView: FrostBarView(model: model, actions: actions))
        // Provide only the ideal size; the controller sizes the hosting view and the window (below the Frost icon).
        hostingView.sizingOptions = [.intrinsicContentSize]
        // The content's size changed (called while SwiftUI updates, before the new content is drawn): resize the
        // window right away so frame and content change in the same frame. Never from a later run loop turn: the new
        // content would be drawn into the old frame first.
        hostingView.onIntrinsicSizeChange = { [weak self] in
            guard let self, self.isOpen || self.prerenderTask != nil else { return }
            self.reposition(allowShrink: false)
        }
        panel.contentView = hostingView
        panel.onCancel = { [weak self] in self?.close(reason: "Esc") }
        panel.onSecondaryClick = { [weak self] in
            guard let self, self.isOpen else { return false }
            guard let id = self.hoveredTile, self.model.state.items.contains(where: { $0.windowID == id }) else {
                let hovered = self.hoveredTile.map(String.init) ?? "none"
                FrostLog.frostBar.debug("right click in the Frost Bar but not on a tile (hovered: \(hovered, privacy: .public))")
                return false
            }
            self.activate(id, click: .secondary)
            return true
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isOpen else { return }
                let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
                let key = NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none"
                FrostLog.frostBar.notice("""
                    Frost Bar resigned key (frontmost app \(front, privacy: .public), Frost key window \
                    \(key, privacy: .public))
                    """)
                self.close(reason: "panel resigned key")
            }
        })
        self.panel = panel
        self.hostingView = hostingView
        return panel
    }

    // MARK: - Warm-up

    /// Prepares the first open at launch so it looks exactly like every later one. Without it, the first click pays
    /// for everything at once on the main thread (in the VM: 0.3 s with the disk cache, 1.4 s without, before the
    /// panel appears, then dropped frames during the appearance animation): reading and decoding the disk cache,
    /// building the panel and its SwiftUI view graph, loading app icons, creating the window and rendering the glass
    /// for the first time.
    ///
    /// Once the scan has the hidden items' owners (or after a few seconds), loads every item's disk-cached capture in
    /// the background, then (in Frost Bar mode) builds the panel and has it render once, invisibly, at its real
    /// position: the window is fully transparent and ignores the mouse while it renders, then it is ordered out. A
    /// click on the Frost icon meanwhile simply opens the panel (`present` ends the warm-up).
    func warmUp() {
        Task { [weak self] in
            for _ in 0..<Self.warmUpAttempts {
                guard let self, !self.isOpen else { return }
                if self.isReadyToWarmUp { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let self, !self.isOpen, self.app.permissions.canManageItems else { return }
            // Without Screen Recording there is nothing to load or capture: tiles show app icons.
            let canCapture = self.app.permissions.canCaptureImages
            if canCapture {
                // Every item, the Visible section's too: the layout editor shows them all.
                await self.app.capturer.preloadCached(self.app.scanner.items)
                self.preloadOnceOwnersAreKnown()
                // Visible items are on screen and can be captured in either display mode; the layout editor shows
                // them.
                let visible = self.app.layout[.visible, default: []].filter(\.isOnScreen)
                let missing = self.app.capturer.missing(visible)
                if !missing.isEmpty, !self.app.mover.isBusy { await self.app.capturer.capture(missing) }
            }
            guard !self.isOpen, self.usesFrostBar else { return }
            #if DEBUG
            if let screen = self.app.sections.iconWindow?.screen ?? NSScreen.main {
                FrameProbe.mark("frostbar-warmup", on: screen, duration: .milliseconds(600))
            }
            #endif
            self.prerender()
            if canCapture { await self.warmUpCapturePipeline() }
        }
    }

    /// The first live refresh round pays one-time setup costs on the main thread (measured in the VM:
    /// ScreenCaptureKit's first capture sets up a media clock, the first window list lookup by ID connects to the
    /// window server), which made the first open after launch hitch while every later one was smooth. Pay them now,
    /// while nothing is shown: one freeze-frame-style screenshot, one look-up of Frost's own windows, and one capture
    /// of the Visible section's items (the strip capture path; it also refreshes their cached images).
    private func warmUpCapturePipeline() async {
        try? await Task.sleep(for: Self.prerenderDuration)
        guard !isOpen else { return }
        await MenuBarFreezeFrame.warmUp(managedDisplayID: managedDisplayID, contentCache: app.capturer.contentCache)
        if let controls = app.sections.controlWindows { _ = StatusWindowParser.windows(withIDs: controls.all) }
        guard !isOpen, !app.mover.isBusy else { return }
        let visible = app.layout[.visible, default: []].filter(\.isOnScreen)
        if !visible.isEmpty { await app.capturer.capture(visible) }
        FrostLog.frostBar.info("warm-up: capture pipeline ready")
    }

    /// The disk cache is keyed by an item's owner, which is read through Accessibility and may not be known yet at
    /// warm-up (measured on a notched MacBook: 12 of 17 cached images loaded at launch; the five pushed-out items only
    /// when the layout editor opened, which showed their app-icon placeholders for ~0.3 s). Poll briefly for the
    /// remaining owners and preload again once they are known.
    private func preloadOnceOwnersAreKnown() {
        guard app.scanner.items.contains(where: { $0.bundleID == nil }) else { return }
        Task { [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                if !self.app.scanner.items.contains(where: { $0.bundleID == nil }) { break }
            }
            guard let self, self.app.permissions.canCaptureImages else { return }
            await self.app.capturer.preloadCached(self.app.scanner.items)
        }
    }

    private var prerenderTask: Task<Void, Never>?
    private static let warmUpAttempts = 20
    /// How long the transparent panel stays ordered in during the warm-up (a few frames).
    private static let prerenderDuration: Duration = .milliseconds(300)

    /// The scan is usable and every hidden item's owner is known (the disk cache is keyed by it).
    private var isReadyToWarmUp: Bool {
        guard app.permissions.canManageItems, app.scanner.status == .ok, app.sections.controlWindows != nil else {
            return false
        }
        let layout = app.layout
        return (layout[.hidden, default: []] + layout[.alwaysHidden, default: []]).allSatisfy { $0.bundleID != nil }
    }

    /// Whether a click on the Frost icon would open the Frost Bar on some display.
    private var usesFrostBar: Bool {
        let preferences = app.preferences
        return NSScreen.screens.contains {
            preferences.effectiveDisplayMode(for: $0, capabilities: app.permissions.capabilities) == .frostBar
        }
    }

    /// Orders the panel in, fully transparent and click-through, with its content in the presented state, so the
    /// view graph, images, glass and window are created and rendered once; `endPrerender` orders it out again.
    private func prerender() {
        let panel = panel ?? makePanel()
        guard !panel.isVisible else { return }
        model.isPresented = true
        reposition()
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        prerenderTask = Task { [weak self] in
            try? await Task.sleep(for: Self.prerenderDuration)
            self?.endPrerender()
        }
        FrostLog.frostBar.info("warm-up: panel rendered off view")
    }

    /// Ends the warm-up render (also called by `present`, which then takes over the ordered-in panel).
    private func endPrerender() {
        guard let task = prerenderTask else { return }
        prerenderTask = nil
        task.cancel()
        guard let panel else { return }
        if !isOpen {
            panel.orderOut(nil)
            model.isPresented = false
        }
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
    }

    // MARK: - Positioning

    /// Places the panel by its content size: right edge aligned with the Frost icon's right edge, dropping down (at
    /// least 8 pt from the visible area's sides), top edge 6 pt below the menu bar. The panel follows the system
    /// appearance; monochrome glyphs are tinted for the glass's actual brightness (see `FrostBarState.templates`).
    ///
    /// Size changes while the panel is visible (`allowShrink == false`, called synchronously when SwiftUI reports a new
    /// content size, before drawing it): growing is applied at once, with implicit animations disabled, so the window
    /// frame and the content change in the same frame. Shrinking waits until the content has finished animating
    /// (`shrinkDelay`): the content is pinned to the window's top-trailing corner (`TopTrailingPin`), so the leftover
    /// margin is invisible, and a section that fades out keeps its room until it's gone.
    ///
    /// Multiple displays: the icon window is the real window, always on the display with the active menu bar. Clicking
    /// the snowflake on a screen makes that screen's menu bar active (the real window has already moved there before
    /// the click is handled; if the click never reaches the button, `SectionController` replays it, see
    /// `ReplicaClickDetector`). So the panel opens below the clicked screen's snowflake, and forwarded menus open on
    /// that screen too.
    private func reposition(allowShrink: Bool = true) {
        guard let panel, let hostingView else { return }
        let iconWindow = app.sections.iconWindow
        guard let screen = iconWindow?.screen ?? NSScreen.screens.first else { return }
        let iconFrame = iconWindow?.frame
        let menuBarHeight = PanelPlacement.menuBarHeight(screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                                                         fallback: iconFrame?.height ?? 24)
        let maxWidth = PanelPlacement.maxContentWidth(visibleFrame: screen.visibleFrame)
        let maxHeight = PanelPlacement.maxContentHeight(screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                                                        menuBarHeight: menuBarHeight)
        if model.maxWidth != maxWidth { model.maxWidth = maxWidth }
        if model.maxHeight != maxHeight { model.maxHeight = maxHeight }
        let content = Self.contentSize(of: hostingView)
        var size = content
        if allowShrink {
            shrinkTask?.cancel()
            shrinkTask = nil
        } else if panel.isVisible {
            size = CGSize(width: max(size.width, panel.frame.width), height: max(size.height, panel.frame.height))
            if size != content { scheduleShrink() }
        }
        let frame = PanelPlacement.frame(size: size, inset: FrostBarMetrics.inset, topInset: FrostBarMetrics.topInset,
                                         anchorMaxX: returnAnchorMaxX ?? iconFrame?.maxX ?? screen.visibleFrame.maxX,
                                         screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                                         menuBarHeight: menuBarHeight)
        guard panel.frame != frame else { return }
        #if DEBUG
        if panel.isVisible { FrameProbe.note("resize(\(Int(panel.frame.width))x\(Int(panel.frame.height))->\(Int(frame.width))x\(Int(frame.height)))") }
        #endif
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            // The resize can happen inside an animated SwiftUI update (⌥-click shows the Always Hidden section): keep
            // the window's new bounds out of that animation.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { panel.setFrame(frame, display: false) }
        }
        CATransaction.commit()
    }

    /// The SwiftUI content's size (its ideal size).
    private static func contentSize(of hostingView: NSView) -> CGSize {
        let size = hostingView.intrinsicContentSize
        guard size.width != NSView.noIntrinsicMetric, size.height != NSView.noIntrinsicMetric else {
            return hostingView.fittingSize
        }
        return size
    }

    /// Shrinks the window to the content once the content has stopped changing (see `reposition`).
    private func scheduleShrink() {
        shrinkTask?.cancel()
        shrinkTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.shrinkDelay) } catch { return }
            guard let self, self.isOpen else { return }
            self.shrinkTask = nil
            self.reposition(allowShrink: true)
        }
    }

    private var shrinkTask: Task<Void, Never>?
    /// Longer than the content's own animations (`FrostBarMetrics.sectionAnimation`, the appearance animation).
    private static let shrinkDelay: Duration = .milliseconds(400)

    /// Repositions when the content (icons, screenshots, state) changes, even if the size doesn't (e.g. only the ⌥
    /// state or a screenshot changed; also catches a screen change). Size changes themselves are applied right away
    /// through `FrostBarHostingView.onIntrinsicSizeChange`.
    private func trackContentSize(_ presentation: Int) {
        withObservationTracking {
            _ = model.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isOpen, self.presentation == presentation else { return }
                self.reposition(allowShrink: false)
                self.trackContentSize(presentation)
            }
        }
    }

    // MARK: - Close on outside click

    private func installMonitors() {
        removeMonitors()
        monitors.add(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            // Clicks in other apps (not Frost's own synthetic events: a new item placed meanwhile, see
            // `NewItemPlacer`).
            global: { [weak self] event in
                guard !SyntheticEvents.isPostedByFrost(event) else {
                    FrostLog.frostBar.debug("ignoring Frost's own synthetic mouse event")
                    return
                }
                self?.close(reason: "click outside (other app)")
            },
            // Clicks in Frost's own windows (settings, onboarding, status items).
            local: { [weak self] event in self?.handleLocalMouseDown(event) })
    }

    private func handleLocalMouseDown(_ event: NSEvent) {
        guard isOpen, event.window !== panel, !SyntheticEvents.isPostedByFrost(event) else { return }
        // A left click on the Frost icon is handled by `toggle` (close or switch ⌥); closing here first would make
        // it reopen immediately.
        if event.window === app.sections.iconWindow, event.type == .leftMouseDown,
           !event.modifierFlags.contains(.control) {
            return
        }
        close(reason: "click outside (Frost window)")
    }

    private func removeMonitors() {
        monitors.removeAll()
    }
}
