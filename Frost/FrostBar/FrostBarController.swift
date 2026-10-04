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
@MainActor
final class FrostBarController {
    let model: FrostBarModel

    private let app: AppModel
    private var panel: FrostBarPanel?
    private var hostingView: FrostBarHostingView?

    private(set) var isOpen = false
    private var monitors: [Any] = []
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
    private var captureTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    /// A delayed retry scheduled after a failed move-back (runs in its own move transaction).
    private var restoreRetryTask: Task<Void, Never>?
    private static let restoreRetryDelay: Duration = .milliseconds(1500)

    /// Items still uncapturable after a temporary expansion (under the notch) keep their disk-cached screenshot or app
    /// icon. When every item is like that, stop expanding (retry only after a layout or display configuration change,
    /// or a manual refresh); see `LiveRefreshPolicy.Conditions.hasCapturableItems`.
    private var retryPolicy = CaptureRetryPolicy()

    /// The live refresh loop (runs while the panel is open, cancelled on close; a round in progress lives in
    /// `captureTask` and isn't interrupted by the cancellation).
    private var liveTask: Task<Void, Never>?
    private var lastCycleStart: ContinuousClock.Instant?
    private var lastCycleEnd: ContinuousClock.Instant?
    /// When the panel was presented this time: the first round waits for the appearance animation to finish
    /// (`LiveRefreshPolicy.appearanceDuration`).
    private var presentedAt: ContinuousClock.Instant?
    private var liveStats = LiveRefreshStats()
    /// The last forwarded click's non-menu presentation may stay on screen after the wait times out / gives up; live
    /// refresh pauses while it's still there.
    private var lingeringPresentation: Set<CGWindowID> = []
    /// Milestones of the click forward in progress, logged once the item has been clicked.
    private var forwardTrace: ForwardTrace?
    /// The tile under the pointer (right clicks go to it, see `FrostBarPanel.onSecondaryClick`).
    private var hoveredTile: CGWindowID?
    /// Set when the item of a finished click forward must stop lingering in the Visible section (the Frost Bar
    /// reopens); quitting cancels the forward instead.
    private var endLingerRequested = false
    /// Environment variable `FROST_LIVE_REFRESH_TRACE=1`: log timings for every round (for measurements in the VM).
    private static let traceCycles = ProcessInfo.processInfo.environment["FROST_LIVE_REFRESH_TRACE"] == "1"

    init(app: AppModel) {
        self.app = app
        model = FrostBarModel(app: app)

        let workspace = NSWorkspace.shared.notificationCenter
        app.capturer.traceStripMismatches = Self.traceCycles
        app.mover.milestone = { [weak self] label, instant in self?.forwardTrace?.mark(label, at: instant) }
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
    private var returnAnchorMaxX: CGFloat?
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
            await self?.flushRestoreRetry()
            guard let self, self.isOpen, !Task.isCancelled else { return }
            await self.prepareLayout()
            guard self.isOpen, !Task.isCancelled else { return }
            // The memory cache is empty after a relaunch: the warm-up has usually loaded the disk cache in the
            // background already (`warmUp`); load whatever it hasn't so the panel shows it as soon as it appears.
            if self.app.permissions.screenRecording { self.app.capturer.loadCached(self.requestedItems) }
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
            openOnboarding: { [weak self] in
                self?.close(animated: false, reason: "onboarding opened")
                self?.app.openOnboarding()
            },
            openSettings: { [weak self] in
                self?.close(animated: false, reason: "settings opened")
                self?.app.openSettings()
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
            guard let self, !self.isOpen, self.app.permissions.allGranted else { return }
            // Every item, the Visible section's too: the layout editor shows them all.
            await self.app.capturer.preloadCached(self.app.scanner.items)
            self.preloadOnceOwnersAreKnown()
            // Visible items are on screen and can be captured in either display mode; the layout editor shows them.
            let visible = self.app.layout[.visible, default: []].filter(\.isOnScreen)
            let missing = self.app.capturer.missing(visible)
            if !missing.isEmpty, !self.app.mover.isBusy { await self.app.capturer.capture(missing) }
            guard !self.isOpen, self.usesFrostBar else { return }
            #if DEBUG
            if let screen = self.app.sections.iconWindow?.screen ?? NSScreen.main {
                FrameProbe.mark("frostbar-warmup", on: screen, duration: .milliseconds(600))
            }
            #endif
            self.prerender()
            await self.warmUpCapturePipeline()
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
            guard let self, self.app.permissions.screenRecording else { return }
            await self.app.capturer.preloadCached(self.app.scanner.items)
        }
    }

    private var prerenderTask: Task<Void, Never>?
    private static let warmUpAttempts = 20
    /// How long the transparent panel stays ordered in during the warm-up (a few frames).
    private static let prerenderDuration: Duration = .milliseconds(300)

    /// The scan is usable and every hidden item's owner is known (the disk cache is keyed by it).
    private var isReadyToWarmUp: Bool {
        guard app.permissions.allGranted, app.scanner.status == .ok, app.sections.controlWindows != nil else {
            return false
        }
        let layout = app.layout
        return (layout[.hidden, default: []] + layout[.alwaysHidden, default: []]).allSatisfy { $0.bundleID != nil }
    }

    /// Whether a click on the Frost icon would open the Frost Bar on some display.
    private var usesFrostBar: Bool {
        let preferences = app.preferences
        return NSScreen.screens.contains {
            preferences.effectiveDisplayMode(for: $0, permissionsGranted: app.permissions.allGranted) == .frostBar
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
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Clicks in other apps (not Frost's own synthetic events: a new item placed meanwhile, see `NewItemPlacer`).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard !SyntheticEvents.isPostedByFrost(event) else {
                FrostLog.frostBar.debug("ignoring Frost's own synthetic mouse event")
                return
            }
            MainActor.assumeIsolated { self?.close(reason: "click outside (other app)") }
        }) {
            monitors.append(global)
        }
        // Clicks in Frost's own windows (settings, onboarding, status items).
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleLocalMouseDown(event) }
            return event
        }) {
            monitors.append(local)
        }
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
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    // MARK: - Live refresh

    /// (Re)starts the live refresh loop. `immediately`: the next round ignores the 1 s start-to-start interval (panel
    /// opened, ⌥ toggled, manual refresh) but is still `LiveRefreshPolicy.minimumGap` after the previous round ended.
    ///
    /// Each round (`runLiveCycle`): freeze frame over the changing part of the menu bar -> expand temporarily ->
    /// capture -> collapse -> remove the freeze frame; new captures replace the panel's old ones immediately. Pause
    /// rules: `LiveRefreshPolicy.skipReason`.
    private func restartLiveRefresh(immediately: Bool) {
        liveTask?.cancel()
        guard isOpen else { return }
        if immediately { lastCycleStart = nil }
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.delayBeforeNextCycle() else { return }
                if delay > .zero {
                    do { try await Task.sleep(for: delay) } catch { return }
                    // Decide again: the appearance animation may have started later than expected (`present`).
                    continue
                }
                guard let self, self.isOpen, !Task.isCancelled else { return }
                // A round left over from the previous loop is still running (the loop restarted on ⌥ toggle /
                // refresh): wait for it before deciding, or its move transaction counts as "move in flight" and
                // pauses us.
                if let running = self.captureTask {
                    await running.value
                    continue
                }
                if let reason = self.liveRefreshSkipReason() {
                    self.liveStats.skip(reason)
                    do { try await Task.sleep(for: LiveRefreshPolicy.pausedRecheck) } catch { return }
                    continue
                }
                self.liveStats.resume()
                await self.runLiveCycle()
            }
        }
    }

    /// Stops the loop (panel closed). A round in progress ends at its next checkpoint, still collapsing and removing the
    /// freeze frame (`captureWhileExpanded`).
    private func stopLiveRefresh() {
        liveTask?.cancel()
        liveTask = nil
        if captureTask != nil {
            FrostLog.frostBar.notice("panel closed during a live refresh cycle; it will collapse and clean up")
        }
        if let summary = liveStats.summary() { FrostLog.frostBar.notice("live refresh: \(summary, privacy: .public)") }
        liveStats = LiveRefreshStats()
    }

    private func delayBeforeNextCycle() -> Duration {
        let now = ContinuousClock.now
        return LiveRefreshPolicy.delayBeforeNextCycle(sinceLastStart: lastCycleStart.map { now - $0 },
                                                      sinceLastEnd: lastCycleEnd.map { now - $0 },
                                                      sincePresented: presentedAt.map { now - $0 })
    }

    /// Whether this round should run (pure logic in `LiveRefreshPolicy.skipReason`).
    private func liveRefreshSkipReason() -> LiveRefreshPolicy.SkipReason? {
        let ids = requestedItems.map(\.windowID)
        let sections = app.sections
        let conditions = LiveRefreshPolicy.Conditions(
            isPanelOpen: isOpen && panel?.isVisible == true,
            hasPermissions: app.permissions.allGranted,
            isActivationInFlight: activationTask != nil,
            isMoveInFlight: app.mover.isBusy,
            isMouseButtonPressed: NSEvent.pressedMouseButtons != 0,
            isMenuOnScreen: ItemClicker.isMenuOnScreen(),
            isForwardedPresentationOnScreen: isLingeringPresentationOnScreen(),
            isEditing: sections.isEditing,
            isCollapsed: sections.state == .collapsed,
            isPointerOverChangingMenuBar: isPointerOverChangingMenuBar(),
            hasCapturableItems: !ids.isEmpty && !retryPolicy.expandable(ids, in: captureContext()).isEmpty)
        return LiveRefreshPolicy.skipReason(conditions)
    }

    /// Whether a running round should end now (panel closed, mouse button pressed, or pointer entered the changing part
    /// of the menu bar).
    private var shouldAbortCycle: Bool {
        LiveRefreshPolicy.shouldAbortCycle(isPanelOpen: isOpen, isMouseButtonPressed: NSEvent.pressedMouseButtons != 0,
                                           isPointerOverChangingMenuBar: isPointerOverChangingMenuBar())
    }

    private func isPointerOverChangingMenuBar() -> Bool {
        let iconWindow = app.sections.iconWindow
        let strips = MenuBarFreezeFrame.menuBarStrips(fallbackHeight: iconWindow?.frame.height ?? 24, iconFrames: [],
                                                      managedDisplayID: managedDisplayID)
        return LiveRefreshPolicy.isPointerInChangingRegion(NSEvent.mouseLocation, strips: strips.map(\.frame),
                                                           iconFrames: frostIconFrames)
    }

    /// The Frost icon's frame on each display (AppKit coordinates): the real window (on the active menu bar) plus
    /// replicas on other displays.
    private var frostIconFrames: [CGRect] {
        let replicas = app.scanner.replicaIconFrames.values.map(SectionController.appKitFrame(ofCG:))
        return (app.sections.iconWindow.map { [$0.frame] } ?? []) + replicas
    }

    /// The display of the scanned menu bar (the active menu bar).
    private var managedDisplayID: CGDirectDisplayID {
        app.scanner.menuBarDisplay?.id ?? CGMainDisplayID()
    }

    private func isLingeringPresentationOnScreen() -> Bool {
        guard !lingeringPresentation.isEmpty else { return false }
        if ItemClicker.onscreenWindowIDs().isDisjoint(with: lingeringPresentation) {
            lingeringPresentation = []
            return false
        }
        return true
    }

    /// Items the panel shows: the Hidden section (plus the Always Hidden section with ⌥).
    private var requestedItems: [MenuBarItem] {
        let layout = model.layout
        return layout[.hidden, default: []] + (model.showAlwaysHidden ? layout[.alwaysHidden, default: []] : [])
    }

    /// Runs one round (does nothing if the previous one is still running; the loop waits for it first). The round's
    /// body runs in a task that doesn't inherit cancellation (`captureTask`): when the panel closes and the loop is
    /// cancelled, the round still collapses and removes the freeze frame; click forwarding waits for it (`activate`).
    private func runLiveCycle() async {
        guard captureTask == nil else { return }
        let ids = requestedItems.map(\.windowID)
        let alwaysHiddenIDs = Set(model.layout[.alwaysHidden, default: []].map(\.windowID))
        let target: SectionController.State = model.showAlwaysHidden && ids.contains(where: alwaysHiddenIDs.contains)
            ? .expandedAll : .expanded
        let context = captureContext()
        lastCycleStart = .now
        #if DEBUG
        FrameProbe.note("cycle")
        #endif
        // The end time and `captureTask` are updated in the round's own task: on panel close / ⌥ toggle the loop is
        // cancelled and restarted, so a new loop may be the one waiting for this round.
        let task = Task { @MainActor [weak self] () -> Void in
            await self?.captureWhileExpanded(ids, target: target, context: context)
            self?.lastCycleEnd = .now
            self?.captureTask = nil
        }
        captureTask = task
        await task.value
    }

    /// Context for deciding whether items uncapturable under the notch are worth retrying: the collapsed item order
    /// and the display configuration.
    private func captureContext() -> CaptureRetryPolicy.Context {
        let displays = NSScreen.screens.map { screen in
            CaptureRetryPolicy.Display(
                id: (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0,
                frame: screen.frame, scale: screen.backingScaleFactor)
        }
        return CaptureRetryPolicy.Context(items: app.scanner.items, displays: displays)
    }

    /// Under a freeze frame (`MenuBarFreezeFrame`, covering only the changing part of the menu bar): expand
    /// temporarily -> capture the menu bar strip once and crop out each item -> collapse -> remove the freeze frame, so
    /// the user never sees the menu bar change. No expansion if the freeze frame capture fails. Everything from showing
    /// the freeze frame on is one move transaction (mutually exclusive with click forwarding and editor drags); the
    /// freeze frame's screenshot is taken before it, so a click on a tile meanwhile starts its move at once instead of
    /// waiting for the round (the round then gives up without showing anything). Ends early at a checkpoint when
    /// the panel closes, a mouse button is pressed, or the pointer enters the changing part of the menu bar: no more
    /// capturing, but it always collapses and removes the freeze frame. Items still off screen after expanding (under
    /// the notch) are recorded in `retryPolicy` and keep their cached screenshot or app icon without affecting the
    /// cadence.
    private func captureWhileExpanded(_ ids: [CGWindowID], target: SectionController.State,
                                      context: CaptureRetryPolicy.Context) async {
        let sections = app.sections
        let clock = ContinuousClock()
        let start = clock.now
        var timing = LiveRefreshStats.Timing()
        var captured: Set<CGWindowID>?
        /// Items on screen after expanding (the rest are under the notch / don't fit).
        var onScreen: Set<CGWindowID> = []
        let mover = app.mover
        let transactionsBefore = mover.transactionCount
        guard let screenshot = await MenuBarFreezeFrame.capture(
            menuBarFallbackHeight: sections.iconWindow?.frame.height ?? 24, iconFrames: frostIconFrames,
            managedDisplayID: managedDisplayID, contentCache: app.capturer.contentCache)
        else {
            liveStats.freezeFrameFailed()
            return
        }
        // The screenshot must still show the menu bar as it is: give up if a move ran or started meanwhile (e.g. a click
        // on a tile, which closed the panel) or anything else now pauses live refresh. No suspension point between this
        // check and taking the transaction.
        guard !shouldAbortCycle, !mover.isBusy, mover.transactionCount == transactionsBefore, activationTask == nil,
              sections.state == .collapsed else {
            liveStats.aborted()
            return
        }
        do {
            try await mover.transaction { () async -> Void in
                let freeze = await MenuBarFreezeFrame.show(screenshot)
                let shown = clock.now
                timing.freezeFrame = shown - start
                // Every exit path removes the freeze frame (`MenuBarFreezeFrame.maximumDuration` is a safety net).
                defer {
                    freeze.remove()
                    timing.overlay = clock.now - shown
                }
                guard !shouldAbortCycle else { return }
                // Freeze the panel layout while expanded: positions near the notch aren't reliable, and it keeps
                // icons from jumping (screenshots are shown at their own size, see `ItemImageCapturer.sizes`).
                model.frozenLayout = model.layout
                defer { model.frozenLayout = nil }
                var mark = clock.now
                let (prior, expanded) = await sections.temporarilyExpand(target)
                timing.expand = clock.now - mark
                // Don't capture if the expansion wasn't confirmed (timed out): items may still be off screen and
                // would be wrongly recorded as "uncapturable even when expanded".
                if expanded, !shouldAbortCycle {
                    mark = clock.now
                    let wanted = Set(ids)
                    let targets = app.scanner.items.filter { wanted.contains($0.windowID) && $0.isOnScreen }
                    onScreen = Set(targets.map(\.windowID))
                    captured = targets.isEmpty ? [] : await app.capturer.capture(targets)
                    timing.capture = clock.now - mark
                    timing.perWindow = targets.isEmpty ? 0 : app.capturer.lastPerWindowCount
                }
                mark = clock.now
                // Remove the freeze frame only once the collapse (or the state the user asked for meanwhile) is
                // confirmed: keep polling for as long as the freeze frame may stay up.
                let budget = Self.restoreBudget(sinceFreezeFrameShown: clock.now - shown)
                if await sections.restore(prior, timeout: budget) {
                    try? await Task.sleep(for: MenuBarFreezeFrame.settleDelay)
                } else {
                    FrostLog.frostBar.error("""
                        the menu bar was not confirmed restored within \(budget, privacy: .public); \
                        removing the freeze frame at its time limit
                        """)
                }
                timing.collapse = clock.now - mark
            }
        } catch {
            // `.busy`: another move transaction just started (rare; the pause rules already checked). Retry next round.
            return
        }
        timing.total = clock.now - start
        guard let captured else {
            liveStats.aborted()
            return
        }
        // Only items still off screen after expanding count as uncapturable (items whose capture failed once are
        // simply retried next round).
        retryPolicy.recordAttempt(ids, stillMissing: Set(ids).subtracting(onScreen), in: context)
        liveStats.record(timing, captured: captured.count, of: ids.count)
        if Self.traceCycles || liveStats.cycles == 1 {
            FrostLog.frostBar.notice(
                "live refresh cycle: captured \(captured.count) of \(ids.count) item(s); \(timing.description, privacy: .public)")
        }
    }

    /// How long a round may wait for the menu bar to be restored: until shortly before the freeze frame's safety net
    /// (`MenuBarFreezeFrame.maximumDuration`), leaving time for `settleDelay`; never less than a short minimum.
    static func restoreBudget(sinceFreezeFrameShown elapsed: Duration) -> Duration {
        let remaining = MenuBarFreezeFrame.maximumDuration - elapsed - MenuBarFreezeFrame.settleDelay - restoreMargin
        return max(remaining, minimumRestoreBudget)
    }

    private static let restoreMargin: Duration = .milliseconds(100)
    private static let minimumRestoreBudget: Duration = .milliseconds(300)

    private func refresh() {
        guard refreshTask == nil else { return }
        model.isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            self.app.permissions.refresh()
            await self.app.scanner.refreshOwnership()
            self.retryPolicy.reset()
            self.restartLiveRefresh(immediately: true)
            // Let the refresh animation complete at least one full turn.
            try? await Task.sleep(for: .milliseconds(500))
            self.model.isRefreshing = false
            self.refreshTask = nil
        }
    }

    // MARK: - Click forwarding

    /// An icon in the panel was clicked: close the panel, temporarily move the original icon into the Visible section
    /// (right of the Frost icon), click it, and move it back once its menu / popover closes. The whole flow is one move
    /// transaction, mutually exclusive with layout editor moves; if another transaction is running it waits for it (up
    /// to `moverWait`) before giving up on the click.
    ///
    /// The activation hand-off (`ActivationHandOff`) begins synchronously while handling the user's click event: only
    /// then does Frost's cooperative activation count as user intent.
    func activate(_ id: CGWindowID, click: ForwardedClick = .primary) {
        guard activationTask == nil else { return }
        endLingerRequested = false
        forwardTrace = ForwardTrace()
        close(reason: "click forward")
        let handOff = ActivationHandOff.begin(for: app.scanner.items.first { $0.windowID == id })
        forwardTrace?.mark("closed")
        activationTask = Task { [weak self] in
            guard let self else {
                handOff?.finish()
                return
            }
            self.forwardTrace?.mark("started")
            // A live refresh round holds the move transaction (temporary expansion): wait for it to collapse and
            // remove its freeze frame before moving. A round still taking its freeze-frame screenshot doesn't hold it
            // and gives up once it sees this click (`captureWhileExpanded`): no need to wait for it.
            if let capture = self.captureTask, self.app.mover.isBusy {
                FrostLog.frostBar.notice("activation waits for the live refresh cycle to restore the collapsed state")
                await capture.value
                self.forwardTrace?.mark("liveRefreshDone")
            }
            // The previous move-back failed and awaits a retry: retry now, or it would stay in the Visible section
            // after this move.
            await self.flushRestoreRetry()
            await self.forward(id, click: click, handOff: handOff)
            // On error (e.g. the move out failed) `clickAndWait` may not have run: make sure activation is handed back.
            handOff?.finish()
            self.forwardTrace = nil
            self.activationTask = nil
        }
    }

    /// How long a click forward waits for another move transaction to finish before it is dropped.
    private static let moverWait: Duration = .seconds(2)

    /// The current (or most recent) click forwarding task; tests and reopening the panel wait for it.
    var pendingActivation: Task<Void, Never>? { activationTask }

    /// Whether a click forward, capture round, or move-back retry is still pending (quitting must wait for them, or a
    /// moved-out icon would stay in the Visible section).
    var hasPendingWork: Bool { activationTask != nil || captureTask != nil || restoreRetryTask != nil }

    /// Called before quitting: cancels a click forward waiting for its menu to close (it still moves back after
    /// cancellation; the menu wait has no limit, so this is the only way to end it), runs any pending move-back retry
    /// right away, and waits for both.
    func prepareForTermination() async {
        close(animated: false, reason: "quitting")
        if let activation = activationTask {
            activation.cancel()
            await activation.value
        }
        if let capture = captureTask { await capture.value }
        await flushRestoreRetry()
    }

    /// If a move-back retry is pending: skip the remaining delay, run it now, and wait for it.
    private func flushRestoreRetry() async {
        guard let retry = restoreRetryTask else { return }
        retry.cancel()
        await retry.value
    }

    private func forward(_ id: CGWindowID, click: ForwardedClick, handOff: ActivationHandOff?) async {
        let mover = app.mover
        // Another transaction (an editor drop, a new-item placement) holds the mover: wait for it (bounded) instead of
        // silently dropping the user's click. No suspension point between the wait and `transaction`, so nothing can
        // slip in once it is idle.
        if mover.isBusy {
            FrostLog.frostBar.notice("activation waits for another move to finish")
            guard await mover.waitUntilIdle(timeout: Self.moverWait), !Task.isCancelled else {
                FrostLog.frostBar.error("activate dropped: another move was still in progress after \(Self.moverWait, privacy: .public)")
                return
            }
        }
        do {
            try await mover.transaction { try await self.moveOutClickAndRestore(id, click: click, handOff: handOff) }
        } catch ItemMoveError.busy {
            FrostLog.frostBar.notice("activate ignored: another move is in progress")
        } catch ItemMoveError.shuttingDown {
            FrostLog.frostBar.notice("activate ignored: Frost is quitting")
        } catch is CancellationError {
            // Only `prepareForTermination` cancels a forward; the icon has been moved back by now.
            FrostLog.frostBar.notice("activate ended early: Frost is quitting")
        } catch {
            FrostLog.frostBar.error("activate failed: \(error, privacy: .public)")
        }
    }

    private func moveOutClickAndRestore(_ id: CGWindowID, click: ForwardedClick,
                                        handOff: ActivationHandOff?) async throws {
        let sections = app.sections, scanner = app.scanner, mover = app.mover
        forwardTrace?.mark("transaction")
        guard !sections.isEditing else { throw FrostBarError.editing }
        if sections.state != .collapsed {
            sections.setState(.collapsed)
            await sections.waitForSettle()
        }
        scanner.rescan()
        // With an unknown owner only menus (layer 101) can be detected, not popovers (layer 25, matched by owner): after
        // 1 s of "nothing opened" the icon would be moved back while its popover is open. Force an ownership read first.
        if scanner.items.first(where: { $0.windowID == id })?.pid == nil {
            await scanner.refreshOwnership()
            if scanner.items.first(where: { $0.windowID == id })?.pid == nil {
                FrostLog.frostBar.notice("owner of item \(id) is unknown; only menus (not popovers) will be detected")
            }
        }
        guard let controls = sections.controlWindows else { throw FrostBarError.controlsMissing }
        let layout = SectionAssigner.layout(of: scanner.items, controls: controls)
        guard let plan = RestorePlan.make(for: id, in: layout, controls: controls) else {
            // Already in the Visible section (e.g. the user just moved it there): just click it.
            guard layout[.visible, default: []].contains(where: { $0.windowID == id }) else {
                throw FrostBarError.itemNotFound
            }
            try await clickAndWait(id, click: click, strayBaseline: nil, handOff: handOff)
            return
        }

        var failure: Error?
        // Window snapshot before the move, to detect a menu accidentally opened by the ⌘-drag (see `clickAndWait`).
        let beforeMove = ItemClicker.onscreenWindowIDs()
        do {
            forwardTrace?.mark("moveStart")
            // Click as soon as the item has reached its final frame (the windows left of it may still be sliding, which
            // doesn't move it or its menu; see `LandingDetector`).
            try await mover.move(id, to: .rightOf(controls.icon), until: .itemLanded)
            forwardTrace?.mark("moved")
            let outcome = try await clickAndWait(id, click: click, strayBaseline: beforeMove, handOff: handOff)
            // A presentation still on screen (timed out / abandoned) isn't the user's to keep using: move back now.
            if outcome == .closed || outcome == .notPresented { try await linger(id) }
        } catch {
            failure = error
        }
        // Move back: success, failure, and cancellation share this path. It runs in a task that doesn't inherit
        // cancellation so it still happens when cancelled. If the move out never took effect, `move` finds the item
        // already in place and returns.
        let cancelled = failure is CancellationError
        // The Frost Bar is opening (it ended the linger): place it under the Frost icon's final position and let it
        // appear as soon as the item has been dropped, not after the ~0.4 s slide of the icons
        // (`LingerReturnAnchor`).
        let opening = endLingerRequested && isOpen && !cancelled
        if opening { predictReturnAnchor(of: id, controls: controls) }
        let completion: ItemMover.Completion = returnAnchorMaxX != nil ? .itemLanded : .settled
        let restoreError = await Task { @MainActor in
            if cancelled { await self.closePresentation(of: id, openedAfter: beforeMove) }
            return await self.restore(plan, controls: controls, until: completion)
        }.value
        if let restoreError {
            if case ItemMoveError.controlsDisturbed = restoreError {
                // Routing fell back to position and dragged the Frost icon; retrying would just drag it again.
                FrostLog.frostBar.error("restore failed: Frost's controls were disturbed; not retrying")
            } else {
                FrostLog.frostBar.error("restore failed: \(restoreError, privacy: .public); retrying in 1.5 s")
                scheduleRestoreRetry(plan, controls: controls)
            }
        }
        if let failure { throw failure }
    }

    /// Records where the Frost icon will be once the lingering item `id` (its right-hand neighbor) has moved back, for
    /// the opening Frost Bar's placement (`returnAnchorMaxX`); leaves it nil when that can't be predicted.
    private func predictReturnAnchor(of id: CGWindowID, controls: FrostControlWindows) {
        let windows = StatusWindowParser.windows(withIDs: [controls.icon, id])
        guard let icon = windows.first(where: { $0.windowID == controls.icon }), icon.isOnScreen,
              let item = windows.first(where: { $0.windowID == id }), item.isOnScreen else { return }
        returnAnchorMaxX = LingerReturnAnchor.iconMaxX(icon: icon.frame, item: item.frame)
    }

    /// Moves the item back to its original section. If the anchor destination fails (anchor gone, move didn't take
    /// effect, under the notch... any error except disturbed Frost control items), tries the section boundary once.
    /// A vanished item (its app quit) counts as success.
    private func restore(_ plan: RestorePlan, controls: FrostControlWindows,
                         until completion: ItemMover.Completion = .settled) async -> Error? {
        let scanner = app.scanner, mover = app.mover
        scanner.rescan()
        let destination = plan.destination(in: SectionAssigner.layout(of: scanner.items, controls: controls))
        do {
            try await mover.move(plan.itemID, to: destination, until: completion)
            return nil
        } catch ItemMoveError.itemNotFound {
            // The app quit: nothing to move back.
            return nil
        } catch ItemMoveError.controlsDisturbed {
            // Another move would just drag the Frost icon again (`ItemMover` already tried to put it back).
            return ItemMoveError.controlsDisturbed
        } catch {
            guard destination != plan.boundary else { return error }
            FrostLog.frostBar.error("""
                restore to \(String(describing: destination), privacy: .public) failed \
                (\(error, privacy: .public)); falling back to the section boundary
                """)
            do {
                try await mover.move(plan.itemID, to: plan.boundary)
                return nil
            } catch ItemMoveError.itemNotFound {
                return nil
            } catch {
                return error
            }
        }
    }

    /// After a failed move-back, tries once more in a new move transaction after `restoreRetryDelay` (e.g. occasional
    /// failures caused by drag remnants succeed on a later retry). Cancelling the task (quit, next click forward) skips
    /// the remaining delay and retries immediately.
    private func scheduleRestoreRetry(_ plan: RestorePlan, controls: FrostControlWindows) {
        restoreRetryTask?.cancel()
        restoreRetryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.restoreRetryDelay)
            // The retry itself runs in a task that doesn't inherit cancellation; cancelling only skips the delay.
            await Task { @MainActor [weak self] in await self?.retryRestore(plan, controls: controls) }.value
            self?.restoreRetryTask = nil
        }
    }

    private func retryRestore(_ plan: RestorePlan, controls: FrostControlWindows) async {
        let mover = app.mover, sections = app.sections
        // Wait up to 5 s for a running transaction (editor drag etc.) to finish.
        _ = await mover.waitUntilIdle(timeout: .seconds(5))
        do {
            // Putting the icon back is exactly what quitting waits for, so it may run while shutting down.
            try await mover.transaction(allowedDuringShutdown: true) {
                if sections.isEditing {
                    // While editing, positions may be under the notch and unreliable: collapse temporarily to move.
                    try await sections.whileCollapsedForMove { try await self.restoreIfNeeded(plan, controls: controls) }
                } else {
                    if sections.state != .collapsed {
                        sections.setState(.collapsed)
                        await sections.waitForSettle()
                    }
                    try await restoreIfNeeded(plan, controls: controls)
                }
            }
            FrostLog.frostBar.notice("delayed restore succeeded")
        } catch {
            FrostLog.frostBar.error("delayed restore failed: \(error, privacy: .public)")
        }
    }

    /// Moves the item back if it's still outside its original section; does nothing if it's back or gone.
    private func restoreIfNeeded(_ plan: RestorePlan, controls: FrostControlWindows) async throws {
        let scanner = app.scanner
        scanner.rescan()
        let controls = app.sections.controlWindows ?? controls
        let layout = SectionAssigner.layout(of: scanner.items, controls: controls)
        guard let current = MenuBarSection.allCases.first(where: { section in
            layout[section, default: []].contains { $0.windowID == plan.itemID }
        }), current != plan.section else { return }
        if let error = await restore(plan, controls: controls) { throw error }
    }

    /// Clicks the item once its frame is stable and waits for its menu / popover to close (returns right away if
    /// nothing opens within 1 s). Menus have no wait limit (they always close when the user clicks elsewhere);
    /// popovers / panels wait up to 60 s (some don't close on an outside click), see `ItemClicker.closeWaitLimit`.
    /// When Frost quits, `prepareForTermination` cancels the wait and the item is moved back as usual.
    ///
    /// Activation hand-off: when a non-menu presentation is detected, activation goes to that app
    /// (`handOff.activateTarget()`; menus are not handed off, see `ActivationHandOff`), and after the wait it's handed
    /// back if Frost is still frontmost (`handOff.finish()`). While waiting, `OutsideClickFallback` handles non-menu
    /// presentations that don't close on an outside click: Esc -> click the item again -> give up waiting.
    ///
    /// The ⌘-drag's mouse-down occasionally makes the moved item open its menu (seen on real hardware, at its pre-move
    /// position with hidden items off screen); clicking again would just close it and the user would see nothing. So
    /// before clicking, check whether the item's app opened new windows during the move (after `strayBaseline`): if
    /// so, close them with a mouse click first (AXPress doesn't work during menu tracking), wait for them to go, then
    /// click normally. Skipped when the owner is unknown. `strayBaseline` holds only the on-screen windows before the
    /// move; `ItemClicker.newWindows` excludes all status bar windows (the moved item's own window was off screen
    /// before the move; Control Center's own items are owned by Control Center) and drag remnants at layer >= 500.
    @discardableResult
    private func clickAndWait(_ id: CGWindowID, click: ForwardedClick, strayBaseline: Set<CGWindowID>?,
                              handOff: ActivationHandOff?) async throws -> PresentationOutcome {
        defer { handOff?.finish() }
        let item = try await settledOnScreenItem(id)
        forwardTrace?.mark("onScreen")
        if let strayBaseline, let pid = item.pid,
           !ItemClicker.newWindows(ownedBy: pid, excluding: strayBaseline).isEmpty {
            FrostLog.frostBar.notice("a presentation opened during the move; dismissing it before clicking")
            try await ItemClicker.click(item, forceEvent: true)
            try await waitUntilDismissed(pid: pid, baseline: strayBaseline)
        }
        let baseline = ItemClicker.onscreenWindowIDs()
        let fallback = OutsideClickFallback(item: item, baseline: baseline)
        // Every exit path (closed, abandoned, timed out, cancelled, error) removes the mouse monitors.
        defer { fallback?.stop() }
        forwardTrace?.mark("click")
        try await ItemClicker.click(item, kind: click)
        forwardTrace?.mark("clicked")
        if let trace = forwardTrace {
            FrostLog.frostBar.notice("""
                click forward (\(click.logName, privacy: .public)) of \(id, privacy: .public): \
                \(trace.description, privacy: .public)
                """)
            forwardTrace = nil
        }
        lingeringPresentation = []
        let hooks = Self.nonMenuHooks(fallback: fallback, handOff: handOff) { [weak self] windows in
            await self?.recordPresentation(windows)
        }
        let outcome = try await ItemClicker.waitForPresentationToClose(baseline: baseline, ownerPID: item.pid,
                                                                       nonMenuHooks: hooks)
        if outcome == .timedOut || outcome == .abandoned {
            // The presentation may still be on screen: Frost Bar live refresh pauses until it's gone
            // (`LiveRefreshPolicy`).
            FrostLog.frostBar.notice("presentation of item \(id): \(String(describing: outcome), privacy: .public); restoring the icon")
        } else {
            lingeringPresentation = []
        }
        fallback?.stop()
        // The presentation is over: hand activation back early (no need to wait for the move back).
        handOff?.finish()
        // Warm the screenshot cache while we're here: the item is in the Visible section with its menu closed (no
        // pressed highlight); once back in the Hidden section it can't be captured. Skipped when the Frost Bar is
        // waiting to open (it ends the linger at once; its live refresh captures the item anyway).
        if app.permissions.screenRecording, !endLingerRequested {
            app.scanner.rescan()
            if let fresh = app.scanner.items.first(where: { $0.windowID == id && $0.isOnScreen }) {
                await app.capturer.capture([fresh])
            }
        }
        return outcome
    }

    // MARK: - Linger

    /// After the forwarded click's presentation closed, keeps the item in the Visible section while the user is still
    /// using it there (pointer on its slot, clicking it again for its other menu), so a follow-up click doesn't hit an
    /// empty slot. Decisions: `ForwardLinger`; this polls every 100 ms. Ends at once when the Frost Bar reopens or the
    /// layout editor opens; while the user is away it pauses (no moves). Quitting cancels the task (the sleep throws),
    /// and the caller closes any open presentation and moves the item back as usual.
    private func linger(_ id: CGWindowID) async throws {
        let pid = app.scanner.items.first { $0.windowID == id }?.pid
        var state = ForwardLinger(start: .now)
        var baseline = ItemClicker.onscreenWindowIDs()
        let watcher = ItemClickWatcher()
        defer { watcher.stop() }
        while true {
            if endLingerRequested || app.sections.isEditing {
                FrostLog.frostBar.notice("linger of item \(id, privacy: .public) ended early; moving it back")
                return
            }
            try await Task.sleep(for: Self.lingerPoll)
            // The app quit (item gone): nothing to keep out.
            guard let window = StatusWindowParser.windows(withIDs: [id]).first, window.isOnScreen else { return }
            watcher.frame = window.frame
            if app.presence.isAway { continue }
            let presentation = ItemClicker.presentation(excluding: baseline, ownerPID: pid)
            let sample = ForwardLinger.Sample(
                time: .now, isPointerOverItem: Self.menuBarRow(of: window.frame,
                                                                display: app.scanner.menuBarDisplay?.frame)
                    .contains(Self.cgPointer()),
                isMouseButtonHeld: UserMouseButtons.isAnyHeld, clickedItem: watcher.consumeClick(),
                isPresentationOpen: !presentation.windows.isEmpty, isMenuOpen: presentation.containsMenu)
            if case .restore(let reason) = state.update(sample) {
                FrostLog.frostBar.debug("""
                    linger end: pointer \(String(describing: Self.cgPointer()), privacy: .public), \
                    item \(String(describing: window.frame), privacy: .public)
                    """)
                FrostLog.frostBar.notice("""
                    linger of item \(id, privacy: .public) over (\(reason.rawValue, privacy: .public)); moving it back
                    """)
                return
            }
            if state.acceptsNewBaseline, presentation.windows.isEmpty { baseline = ItemClicker.onscreenWindowIDs() }
        }
    }

    private static let lingerPoll: Duration = .milliseconds(100)

    /// The menu bar row an item sits in (CG coordinates): the display's full width at the item's height. While the
    /// pointer is anywhere in it, a lingering item stays put — moving it back would shift the icons under the pointer.
    private static func menuBarRow(of item: CGRect, display: CGRect?) -> CGRect {
        guard let display else { return item }
        return CGRect(x: display.minX, y: item.minY, width: display.width, height: item.height)
    }

    /// The pointer in CG global coordinates (top-left origin).
    private static func cgPointer() -> CGPoint {
        OutsideClickDismissal.cgPoint(fromAppKit: NSEvent.mouseLocation,
                                      primaryScreenMaxY: NSScreen.screens.first?.frame.maxY ?? 0)
    }

    private func recordPresentation(_ windows: Set<CGWindowID>) {
        lingeringPresentation = windows
    }

    /// When a non-menu presentation appears: record its windows (`record`), hand activation to its app, then install
    /// the outside-click fallback monitors.
    private static func nonMenuHooks(fallback: OutsideClickFallback?, handOff: ActivationHandOff?,
                                     record: @escaping @Sendable (Set<CGWindowID>) async -> Void)
        -> NonMenuPresentationHooks {
        let fallbackHooks = fallback?.hooks
        return NonMenuPresentationHooks(
            presented: { windows in
                await record(windows)
                await handOff?.activateTarget()
                await fallbackHooks?.presented(windows)
            },
            poll: { isFading in await fallbackHooks?.poll(isFading) ?? false })
    }

    /// Waits until all of the app's windows outside `baseline` are gone (up to 1 s; a closed menu's window disappears
    /// in ~0.25 s, a popover's in ~0.5 s).
    /// Quitting cancels the wait for a forwarded click's menu / popover while it may still be open. An open menu
    /// consumes the ⌘-drag's mouse-down, so the move back would fail (and while quitting, a failed move isn't retried
    /// and the item lands at the section boundary instead of its old place): close it first with a click on the item,
    /// as a user would.
    private func closePresentation(of id: CGWindowID, openedAfter baseline: Set<CGWindowID>) async {
        guard let pid = app.scanner.items.first(where: { $0.windowID == id })?.pid,
              !ItemClicker.newWindows(ownedBy: pid, excluding: baseline).isEmpty else { return }
        FrostLog.frostBar.notice("closing the presentation of item \(id) before moving it back")
        do {
            let item = try await settledOnScreenItem(id)
            try await ItemClicker.click(item, forceEvent: true)
            try await waitUntilDismissed(pid: pid, baseline: baseline)
        } catch {
            FrostLog.frostBar.error("closing the presentation of item \(id) failed: \(error, privacy: .public)")
        }
    }

    private func waitUntilDismissed(pid: pid_t, baseline: Set<CGWindowID>) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while clock.now < deadline, !ItemClicker.newWindows(ownedBy: pid, excluding: baseline).isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// After moving out, confirms the item's frame is stable and on screen: the click must land at the final position,
    /// or the menu opens mid-animation. `ItemMover.move` already waited for the item to land in its final frame
    /// (`LandingDetector`) and rescanned; this double-checks via CGWindowList every 10 ms until 2 identical on-screen reads
    /// (the first compared with the scanned frame), up to 1.5 s.
    private func settledOnScreenItem(_ id: CGWindowID) async throws -> MenuBarItem {
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(1500)
        var previous = app.scanner.items.first { $0.windowID == id && $0.isOnScreen }?.frame
        while clock.now < deadline {
            guard let window = StatusWindowParser.windows(withIDs: [id]).first
            else { throw FrostBarError.itemNotFound }
            if window.isOnScreen, window.frame == previous { break }
            previous = window.isOnScreen ? window.frame : nil
            try await Task.sleep(for: .milliseconds(10))
        }
        app.scanner.rescan()
        guard let item = app.scanner.items.first(where: { $0.windowID == id }) else { throw FrostBarError.itemNotFound }
        guard item.isOnScreen else { throw FrostBarError.notOnScreen }
        return item
    }
}

/// Watches for the user's mouse-downs (left or right) on a lingering item's frame (global monitor: the item belongs to
/// another app; local monitor: in case Frost is frontmost). Frost's own synthetic events are ignored.
@MainActor
private final class ItemClickWatcher {
    /// The item's current frame (CG global coordinates); nil = not known yet.
    var frame: CGRect?
    private var clicked = false
    private var monitors: [Any] = []

    init() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseDown(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseDown(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    /// Whether the item was clicked since the last call.
    func consumeClick() -> Bool {
        defer { clicked = false }
        return clicked
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    private func mouseDown(_ event: NSEvent) {
        guard !SyntheticEvents.isPostedByFrost(event), let frame else { return }
        // The event's own location (the pointer may have moved on by now); a global event's is in screen coordinates.
        let screenPoint = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
        let point = OutsideClickDismissal.cgPoint(fromAppKit: screenPoint,
                                                  primaryScreenMaxY: NSScreen.screens.first?.frame.maxY ?? 0)
        if frame.contains(point) { clicked = true }
    }
}
