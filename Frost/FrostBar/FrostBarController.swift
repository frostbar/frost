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
/// clicks it, waits for its menu / popover to close, then moves it back.
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
    /// Environment variable `FROST_LIVE_REFRESH_TRACE=1`: log timings for every round (for measurements in the VM).
    private static let traceCycles = ProcessInfo.processInfo.environment["FROST_LIVE_REFRESH_TRACE"] == "1"

    init(app: AppModel) {
        self.app = app
        model = FrostBarModel(app: app)

        let workspace = NSWorkspace.shared.notificationCenter
        app.capturer.traceStripMismatches = Self.traceCycles
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(animated: false) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.app.capturer.contentCache.invalidate()
                self?.close(animated: false)
            }
        })
    }

    // MARK: - Open / close

    /// The Frost icon was clicked (display mode is Frost Bar). Clicking again closes it; clicking with a different ⌥
    /// state while open shows / hides the Always Hidden section instead.
    func toggle(showAlwaysHidden: Bool) {
        guard isOpen else {
            open(showAlwaysHidden: showAlwaysHidden)
            return
        }
        if showAlwaysHidden != model.showAlwaysHidden {
            model.showAlwaysHidden = showAlwaysHidden
            // Refresh the newly shown section right away (don't wait for the next cycle).
            restartLiveRefresh(immediately: true)
        } else {
            close()
        }
    }

    func open(showAlwaysHidden: Bool) {
        guard !isOpen else { return }
        isOpen = true
        hideTask?.cancel()
        model.showAlwaysHidden = showAlwaysHidden
        liveStats = LiveRefreshStats()
        #if DEBUG
        openCount += 1
        if let screen = app.sections.iconWindow?.screen ?? NSScreen.main {
            FrameProbe.mark("frostbar-open-\(openCount)", on: screen, duration: .milliseconds(1500))
        }
        #endif
        openTask = Task { [weak self] in
            // The previous click forward hasn't finished (e.g. its menu is still open, or it's moving back); wait for
            // it so the layout is final.
            if let activation = self?.activationTask { await activation.value }
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
            // Show cached screenshots first, then start live refresh (the first round runs after the panel's
            // appearance animation, so the freeze frame captures the panel shadow in its final state).
            self.restartLiveRefresh(immediately: true)
        }
    }

    func close(animated: Bool = true) {
        guard isOpen else { return }
        isOpen = false
        openTask?.cancel()
        stopLiveRefresh()
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
        #if DEBUG
        FrameProbe.note("ordered")
        #endif
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
            activate: { [weak self] item in self?.activate(item.windowID) },
            refresh: { [weak self] in self?.refresh() },
            openOnboarding: { [weak self] in
                self?.close(animated: false)
                self?.app.openOnboarding()
            },
            openSettings: { [weak self] in
                self?.close(animated: false)
                self?.app.openSettings()
            })
        let hostingView = FrostBarHostingView(rootView: FrostBarView(model: model, actions: actions))
        // Provide only the ideal size (`fittingSize` relies on it and is 0x0 without it); the controller sets the
        // window frame (below the Frost icon).
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.onIntrinsicSizeChange = { [weak self] in
            // Called during SwiftUI layout: change the window frame on the next turn to avoid re-entrant layout.
            Task { @MainActor [weak self] in
                guard let self, self.isOpen else { return }
                self.reposition()
            }
        }
        panel.contentView = hostingView
        panel.onCancel = { [weak self] in self?.close() }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
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
    /// Once the scan has the hidden items' owners (or after a few seconds), loads their disk-cached captures in the
    /// background, then (in Frost Bar mode) builds the panel and has it render once, invisibly, at its real position:
    /// the window is fully transparent and ignores the mouse while it renders, then it is ordered out. A click on the
    /// Frost icon meanwhile simply opens the panel (`present` ends the warm-up).
    func warmUp() {
        Task { [weak self] in
            for _ in 0..<Self.warmUpAttempts {
                guard let self, !self.isOpen else { return }
                if self.isReadyToWarmUp { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let self, !self.isOpen, self.app.permissions.allGranted else { return }
            let layout = self.app.layout
            await self.app.capturer.preloadCached(layout[.hidden, default: []] + layout[.alwaysHidden, default: []])
            guard !self.isOpen, self.usesFrostBar else { return }
            #if DEBUG
            if let screen = self.app.sections.iconWindow?.screen ?? NSScreen.main {
                FrameProbe.mark("frostbar-warmup", on: screen, duration: .milliseconds(600))
            }
            #endif
            self.prerender()
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
    /// Multiple displays: the icon window is the real window, always on the display with the active menu bar. Clicking
    /// the snowflake on a screen makes that screen's menu bar active (the real window has already moved there before
    /// the click is handled; if the click never reaches the button, `SectionController` replays it, see
    /// `ReplicaClickDetector`). So the panel opens below the clicked screen's snowflake, and forwarded menus open on
    /// that screen too.
    private func reposition() {
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
        let size = hostingView.fittingSize
        let frame = PanelPlacement.frame(size: size, inset: FrostBarMetrics.inset, topInset: FrostBarMetrics.topInset,
                                         anchorMaxX: iconFrame?.maxX ?? screen.visibleFrame.maxX,
                                         screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                                         menuBarHeight: menuBarHeight)
        if panel.frame != frame {
            #if DEBUG
            if panel.isVisible { FrameProbe.note("resize(\(Int(panel.frame.width))x\(Int(panel.frame.height))->\(Int(frame.width))x\(Int(frame.height)))") }
            #endif
            panel.setFrame(frame, display: true)
        }
    }

    /// Repositions when the content (icons, screenshots, state) changes, even if the size doesn't (e.g. only the ⌥
    /// state or a screenshot changed). Size changes are also signalled by `FrostBarHostingView.onIntrinsicSizeChange`,
    /// when SwiftUI has finished layout and `fittingSize` is up to date.
    private func trackContentSize(_ presentation: Int) {
        withObservationTracking {
            _ = model.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isOpen, self.presentation == presentation else { return }
                self.reposition()
                self.trackContentSize(presentation)
            }
        }
    }

    // MARK: - Close on outside click

    private func installMonitors() {
        removeMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Clicks in other apps.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
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
        guard isOpen, event.window !== panel else { return }
        // A left click on the Frost icon is handled by `toggle` (close or switch ⌥); closing here first would make
        // it reopen immediately.
        if event.window === app.sections.iconWindow, event.type == .leftMouseDown,
           !event.modifierFlags.contains(.control) {
            return
        }
        close()
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
    /// the user never sees the menu bar change. No expansion if the freeze frame capture fails. The whole thing is one
    /// move transaction (mutually exclusive with click forwarding and editor drags). Ends early at a checkpoint when
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
        var freezeFrameFailed = false
        do {
            try await app.mover.transaction { () async -> Void in
                guard let freeze = await MenuBarFreezeFrame.show(
                    menuBarFallbackHeight: sections.iconWindow?.frame.height ?? 24, iconFrames: frostIconFrames,
                    managedDisplayID: managedDisplayID, contentCache: app.capturer.contentCache)
                else {
                    freezeFrameFailed = true
                    return
                }
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
                // Remove the freeze frame only once the collapse is confirmed (`restore` waits less than
                // `MenuBarFreezeFrame.maximumDuration`).
                await sections.restore(prior)
                try? await Task.sleep(for: MenuBarFreezeFrame.settleDelay)
                timing.collapse = clock.now - mark
            }
        } catch {
            // `.busy`: another move transaction just started (rare; the pause rules already checked). Retry next round.
            return
        }
        timing.total = clock.now - start
        if freezeFrameFailed {
            liveStats.freezeFrameFailed()
            return
        }
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
    /// transaction, mutually exclusive with layout editor moves; the click is ignored if a transaction is running.
    ///
    /// The activation hand-off (`ActivationHandOff`) begins synchronously while handling the user's click event: only
    /// then does Frost's cooperative activation count as user intent.
    func activate(_ id: CGWindowID) {
        guard activationTask == nil else { return }
        close()
        let handOff = ActivationHandOff.begin(for: app.scanner.items.first { $0.windowID == id })
        activationTask = Task { [weak self] in
            guard let self else {
                handOff?.finish()
                return
            }
            // A live refresh round (temporary expansion) is running: wait for it to collapse and remove its freeze
            // frame before moving (`captureTask` also holds the move transaction).
            if let capture = self.captureTask {
                FrostLog.frostBar.notice("activation waits for the live refresh cycle to restore the collapsed state")
                await capture.value
            }
            // The previous move-back failed and awaits a retry: retry now, or it would stay in the Visible section
            // after this move.
            await self.flushRestoreRetry()
            await self.forward(id, handOff: handOff)
            // On error (e.g. the move out failed) `clickAndWait` may not have run: make sure activation is handed back.
            handOff?.finish()
            self.activationTask = nil
        }
    }

    /// The current (or most recent) click forwarding task; tests and reopening the panel wait for it.
    var pendingActivation: Task<Void, Never>? { activationTask }

    /// Whether a click forward, capture round, or move-back retry is still pending (quitting must wait for them, or a
    /// moved-out icon would stay in the Visible section).
    var hasPendingWork: Bool { activationTask != nil || captureTask != nil || restoreRetryTask != nil }

    /// Called before quitting: cancels a click forward waiting for its menu to close (it still moves back after
    /// cancellation; the menu wait has no limit, so this is the only way to end it), runs any pending move-back retry
    /// right away, and waits for both.
    func prepareForTermination() async {
        close(animated: false)
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

    private func forward(_ id: CGWindowID, handOff: ActivationHandOff?) async {
        do {
            try await app.mover.transaction { try await self.moveOutClickAndRestore(id, handOff: handOff) }
        } catch ItemMoveError.busy {
            FrostLog.frostBar.notice("activate ignored: another move is in progress")
        } catch {
            FrostLog.frostBar.error("activate failed: \(error, privacy: .public)")
        }
    }

    private func moveOutClickAndRestore(_ id: CGWindowID, handOff: ActivationHandOff?) async throws {
        let sections = app.sections, scanner = app.scanner, mover = app.mover
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
            try await clickAndWait(id, strayBaseline: nil, handOff: handOff)
            return
        }

        var failure: Error?
        // Window snapshot before the move, to detect a menu accidentally opened by the ⌘-drag (see `clickAndWait`).
        let beforeMove = ItemClicker.onscreenWindowIDs()
        do {
            try await mover.move(id, to: .rightOf(controls.icon))
            try await clickAndWait(id, strayBaseline: beforeMove, handOff: handOff)
        } catch {
            failure = error
        }
        // Move back: success, failure, and cancellation share this path. It runs in a task that doesn't inherit
        // cancellation so it still happens when cancelled. If the move out never took effect, `move` finds the item
        // already in place and returns.
        let restoreError = await Task { @MainActor in await self.restore(plan, controls: controls) }.value
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

    /// Moves the item back to its original section. If the anchor destination fails (anchor gone, move didn't take
    /// effect, under the notch... any error except disturbed Frost control items), tries the section boundary once.
    /// A vanished item (its app quit) counts as success.
    private func restore(_ plan: RestorePlan, controls: FrostControlWindows) async -> Error? {
        let scanner = app.scanner, mover = app.mover
        scanner.rescan()
        let destination = plan.destination(in: SectionAssigner.layout(of: scanner.items, controls: controls))
        do {
            try await mover.move(plan.itemID, to: destination)
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
    private func clickAndWait(_ id: CGWindowID, strayBaseline: Set<CGWindowID>?,
                              handOff: ActivationHandOff?) async throws {
        defer { handOff?.finish() }
        let item = try await settledOnScreenItem(id)
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
        try await ItemClicker.click(item)
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
        // pressed highlight); once back in the Hidden section it can't be captured.
        if app.permissions.screenRecording {
            app.scanner.rescan()
            if let fresh = app.scanner.items.first(where: { $0.windowID == id && $0.isOnScreen }) {
                await app.capturer.capture([fresh])
            }
        }
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
    private func waitUntilDismissed(pid: pid_t, baseline: Set<CGWindowID>) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while clock.now < deadline, !ItemClicker.newWindows(ownedBy: pid, excluding: baseline).isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// After moving out, confirms the item's frame is stable and on screen: the click must land at the final position,
    /// or the menu opens mid-animation. `ItemMover.move` already waited for all frames to settle (on-screen moves
    /// animate for ~450 ms); this double-checks via CGWindowList every 40 ms until 2 identical reads, up to 1.5 s.
    private func settledOnScreenItem(_ id: CGWindowID) async throws -> MenuBarItem {
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(1500)
        var previous: CGRect?
        var unchanged = 0
        while clock.now < deadline {
            guard let window = StatusWindowParser.currentWindows().first(where: { $0.windowID == id })
            else { throw FrostBarError.itemNotFound }
            unchanged = window.isOnScreen && window.frame == previous ? unchanged + 1 : 0
            previous = window.frame
            if unchanged >= 2 { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        app.scanner.rescan()
        guard let item = app.scanner.items.first(where: { $0.windowID == id }) else { throw FrostBarError.itemNotFound }
        guard item.isOnScreen else { throw FrostBarError.notOnScreen }
        return item
    }
}
