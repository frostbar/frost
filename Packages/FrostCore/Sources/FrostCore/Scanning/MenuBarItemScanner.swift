import AppKit
import Observation

public enum ScanStatus: Equatable, Sendable {
    case notScanned
    case ok
    /// CGWindowList returned no status bar windows on the active menu bar — tell the user explicitly
    /// instead of silently showing an empty list.
    case noWindows
}

/// Scans the menu bar items on the display that hosts the **active menu bar** (with multiple displays the real
/// windows follow the active menu bar, see `MenuBarDisplayResolver`; with a single display it is the main
/// display), and rescans automatically when apps launch or quit, and when status item windows appear or go away
/// without that (`windowWatchInterval`).
///
/// Scanning has two parts:
/// - `rescan()`: synchronous and cheap; reads only CGWindowList and reuses the ownership cached by windowID.
///   Moving, expanding, etc. call it at any time.
/// - `refreshOwnership()`: a full AX read of every process to resolve ownership (about 300 ms; each hung app
///   uses up the full 0.25 s timeout). Reads on a background thread and merges back on the main thread, so it
///   never blocks the main thread. Called on app launch / quit and manual refresh; `rescan()` also triggers one
///   in the background when it finds new windows (or when unresolved windows are due for a retry, see
///   `OwnershipRefreshPolicy`).
@MainActor
@Observable
public final class MenuBarItemScanner {
    /// Where the item list comes from (`MenuBarBackend`): the window list on macOS 26, Accessibility on macOS 27.
    public enum Source: Sendable {
        /// Every status item is a layer-25 window: read CGWindowList, resolve owners through AX.
        case windowList
        /// `MenuBarAgent` draws the whole bar and there are no per-item windows: read the AX extras
        /// (`AXMenuBarInventory`).
        case accessibility
    }

    public let source: Source

    public private(set) var items: [MenuBarItem] = []
    public private(set) var status: ScanStatus = .notScanned
    /// The display `items` are on (the one with the active menu bar, where the real windows are).
    /// nil until the first scan.
    public private(set) var menuBarDisplay: MenuBarDisplay?
    /// Frames (CG) of the Frost icon replicas on other displays, used by the freeze frame and cursor checks.
    @ObservationIgnored public private(set) var replicaIconFrames: [CGDirectDisplayID: CGRect] = [:]

    /// CG frames of the real windows of Frost's three control items (injected by the app layer, converted from
    /// `button.window.frame`): they decide which display has the active menu bar and anchor the distinction
    /// between real windows and other displays' replicas.
    @ObservationIgnored public var controlFrames: () -> FrostControlFrames? = { nil }
    @ObservationIgnored private var lastUnresolved = 0

    /// Ownership from the last successful resolution, cached by windowID (when the active menu bar moves to
    /// another display the real windows keep their windowIDs, so the cache stays valid). If matching fails —
    /// e.g. the active menu bar changed display during the read — the cache is reused so ownership is not lost
    /// (and the clock is not mistaken for a movable item).
    @ObservationIgnored private var ownershipCache: [CGWindowID: AXItemInfo] = [:]

    /// Windows whose ownership was still unresolved after the last full AX read → the time of that read.
    /// These windows trigger a full read at most once per `OwnershipRefreshPolicy.retryInterval` (5 s).
    @ObservationIgnored private var unresolvedSince: [CGWindowID: ContinuousClock.Instant] = [:]
    /// Follow-up reads scheduled since ownership was last fully resolved (see
    /// `OwnershipRefreshPolicy.shouldScheduleRetry`).
    @ObservationIgnored private var scheduledRetries = 0

    /// Frost's own status bar windows (injected by the app layer as `controlWindows.all`). `AXExtrasReader`
    /// skips this process, so these windows are assigned to this process directly and never count as
    /// "unresolved" (which would keep triggering full reads).
    @ObservationIgnored public var ownWindowIDs: () -> Set<CGWindowID> = { [] }

    /// Frost's own status items with their current frames, used by `Source.accessibility` (where no window list can
    /// tell Frost where its own icon and dividers are). Injected by the app layer.
    @ObservationIgnored public var ownItems: () -> [AXMenuBarInventory.OwnItem] = { [] }

    @ObservationIgnored private var runningAppsObservation: NSKeyValueObservation?
    /// How often `start`'s watch looks for status item windows that appeared or went away while no app launched or
    /// quit: an app re-adding its item (hiding and showing it, e.g. an icon that blinks for unread messages) creates a
    /// new window, which macOS puts at the far left, in Always Hidden. Nothing else rescans then, so without the watch
    /// the item would stay there (its remembered section not restored) until some unrelated rescan. A check reads only
    /// the window list; `items` are republished only when the set of windows changed.
    public static let windowWatchInterval: Duration = .seconds(3)
    @ObservationIgnored private var windowWatch: Task<Void, Never>?
    /// The windows `items` were last built from (before stale ones are dropped).
    @ObservationIgnored private var publishedWindowIDs: Set<CGWindowID> = []
    @ObservationIgnored private var pendingRescan: Task<Void, Never>?
    @ObservationIgnored private var pendingRefreshOwnership = false
    @ObservationIgnored private lazy var ownershipRefresher = RefreshCoalescer { [weak self] in
        await self?.performOwnershipRefresh()
    }

    /// How often `Source.accessibility` re-reads the extras when nothing else triggers a scan. An AX read of every
    /// app takes about 300 ms in the background, and items appear and disappear (an app launching, an item blinking
    /// for unread messages) without a window-list change to notice, so a slow poll keeps the list honest without
    /// loading the machine.
    public static let accessibilityWatchInterval: Duration = .seconds(3)
    @ObservationIgnored private var accessibilityWatch: Task<Void, Never>?
    @ObservationIgnored private var axReadInFlight = false
    @ObservationIgnored private var axReadPending = false
    #if DEBUG
    /// The item list the last log line described (Debug builds log it whenever it changes).
    @ObservationIgnored private var lastAccessibilitySummary = ""
    #endif

    public init(source: Source = .windowList) {
        self.source = source
    }

    public func start() {
        // Rescan when apps launch / quit. Uses KVO on `runningApplications` rather than the didLaunch /
        // didTerminate notifications: the system does not post those for LSUIElement (accessory) apps, and most
        // menu bar apps are LSUIElement (verified in the VM).
        runningAppsObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.scheduledRetries = 0
                self?.scheduleRescan(refreshOwnership: true)
            }
        }
        switch source {
        case .windowList:
            rescan()
            ownershipRefresher.refreshInBackground()
            windowWatch = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: Self.windowWatchInterval) } catch { return }
                    guard let self else { return }
                    let windows = self.menuBarWindows()
                    if Set(windows.map(\.windowID)) != self.publishedWindowIDs { self.rescan(windows) }
                }
            }
        case .accessibility:
            accessibilityRescan()
            accessibilityWatch = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: Self.accessibilityWatchInterval) } catch { return }
                    guard let self else { return }
                    self.accessibilityRescan()
                }
            }
        }
    }

    /// Coalesces bursts of triggers: status items often appear a little after an app launches, so scan after
    /// 1 second. If any of the coalesced triggers asked for `refreshOwnership`, the final scan is followed by
    /// a full AX read.
    public func scheduleRescan(after delay: Duration = .seconds(1), refreshOwnership: Bool = false) {
        pendingRefreshOwnership = pendingRefreshOwnership || refreshOwnership
        pendingRescan?.cancel()
        pendingRescan = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            let refresh = self.pendingRefreshOwnership
            self.pendingRefreshOwnership = false
            self.rescan()
            if refresh { await self.refreshOwnership() }
        }
    }

    /// Rescans the active menu bar's items: on macOS 26 synchronous and cheap (reads only CGWindowList and reuses
    /// cached ownership; a full AX read follows in the background when a window needs one), on macOS 27 an AX read
    /// that publishes `items` when it returns.
    public func rescan() {
        switch source {
        case .windowList: rescan(menuBarWindows())
        case .accessibility: accessibilityRescan()
        }
    }

    private func rescan(_ windows: [RawStatusWindow]) {
        cacheOwnWindows(windows)
        publish(windows)
        let needsFullRead = OwnershipRefreshPolicy.needsFullRead(
            // Zero-width, off-screen windows (usually leftovers of apps that quit) don't trigger a full read;
            // otherwise they would trigger one every 5 seconds.
            windowIDs: windows.filter { !StaleWindowFilter.isCandidate($0) }.map(\.windowID),
            cached: Set(ownershipCache.keys), unresolvedSince: unresolvedSince, now: .now)
        if needsFullRead { ownershipRefresher.refreshInBackground() }
    }

    /// Does a full AX read of every process and updates ownership (read in the background, never blocking the
    /// main thread). On return, `items` reflect the new ownership. A read already in flight may have started
    /// before the call (e.g. right after an app launched), so this always waits for a read that starts after
    /// the call; concurrent calls share the same read.
    public func refreshOwnership() async {
        switch source {
        case .windowList: await ownershipRefresher.refresh()
        case .accessibility: await accessibilityRead()
        }
    }

    // MARK: - macOS 27: reading the AX extras

    /// Starts an AX read unless one is running; a request that arrives meanwhile is remembered and served by a
    /// follow-up read, so a caller that just changed something (a divider width, a move) sees the result.
    private func accessibilityRescan() {
        guard !axReadInFlight else {
            axReadPending = true
            return
        }
        axReadInFlight = true
        Task { [weak self] in
            await self?.performAccessibilityRead()
            await self?.finishAccessibilityRead()
        }
    }

    /// An AX read the caller waits for. A read already in flight started before whatever the caller changed, so it
    /// is waited out and one more read — the caller's — is made afterwards; the caller is woken by that read rather
    /// than by polling for a moment with no read running. Polling for a gap looks fine and isn't: the three-second
    /// watch starts the next read in the same turn the previous one ends, so a caller waiting for an idle moment can
    /// wait forever while reads keep completing. Everyone waiting is woken together, by the one extra read.
    private func accessibilityRead() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            axReadWaiters.append(continuation)
            if axReadInFlight { axReadPending = true } else { accessibilityRescan() }
        }
    }

    /// Callers waiting for a fresh read (`accessibilityRead`); woken by the read that serves them.
    @ObservationIgnored private var axReadWaiters: [CheckedContinuation<Void, Never>] = []

    /// Finishes a read (the read itself has already happened): if anyone is waiting, one more read is made and they
    /// are woken — the caller's own read, which starts after whatever it changed; otherwise a read someone asked for
    /// meanwhile is started.
    private func finishAccessibilityRead() async {
        guard !axReadWaiters.isEmpty else {
            axReadInFlight = false
            if axReadPending {
                axReadPending = false
                accessibilityRescan()
            }
            return
        }
        // A caller is waiting: read once more, while still marked in flight so no other read starts meanwhile, and
        // wake exactly those who were waiting when it started. A caller that arrives *during* it wants geometry from
        // after its own change, so it waits for a read of its own rather than being handed this one's older result.
        axReadPending = false
        let waiting = axReadWaiters
        axReadWaiters = []
        await performAccessibilityRead()
        axReadInFlight = false
        for waiter in waiting { waiter.resume() }
        // A watch tick, or a caller that arrived during that read, still gets its own.
        if axReadPending || !axReadWaiters.isEmpty {
            axReadPending = false
            accessibilityRescan()
        }
    }

    private func performAccessibilityRead() async {
        let axItems = await AXExtrasReader.readAllInBackground()
        let displays = Self.currentDisplays()
        let iconFrame = controlFrames()?.icon
        let display = iconFrame.flatMap { frame in
            displays.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }
        } ?? displays.first { $0.id == CGMainDisplayID() } ?? displays.first
        if let display, menuBarDisplay != display {
            menuBarDisplay = display
            let frame = NSStringFromRect(display.frame)
            FrostLog.scanner.notice("""
                managing the menu bar of display \(display.id) \(frame, privacy: .public) \
                (main display \(CGMainDisplayID()))
                """)
        }
        let bounds = display?.frame ?? CGDisplayBounds(CGMainDisplayID())
        let scan = AXMenuBarInventory.scan(axItems: axItems, own: ownItems(), displayBounds: bounds)
        ownershipCache = scan.ownership
        // Every display shows the same items on 27 (one composited bar), so there are no separate replicas to
        // recognize clicks on.
        replicaIconFrames = [:]
        publish(scan.windows)
        #if DEBUG
        // The item list is what every later decision is based on, and on 27 it exists only here (no window list to
        // cross-check against); log it when it changes.
        // IDs and geometry only: a title is the item's AX description, which may be user content
        // (`AGENTS.md`, logging: item titles are private).
        let summary = scan.windows.map { "\($0.windowID)@\(Int($0.frame.minX))/w\(Int($0.frame.width))" }
            .joined(separator: " ")
        if summary != lastAccessibilitySummary {
            lastAccessibilitySummary = summary
            FrostLog.scanner.notice("bar: \(summary, privacy: .public)")
        }
        #endif
    }

    private func performOwnershipRefresh() async {
        let before = menuBarWindows()
        let axItems = await AXExtrasReader.readAllInBackground()
        let after = menuBarWindows()
        // AX frames are the real windows' frames: only use AX items on the scanned row (pushed-out items
        // have a negative x and are kept).
        let relevant = menuBarDisplay.map { DisplayFilter.axItems(axItems, onMenuBarOf: $0) } ?? axItems
        ownershipCache = StaleWindowFilter.ownershipOfLiveProcesses(ownershipCache, isAlive: Self.isProcessAlive)
        for (id, info) in AXItemMatcher.consensusOwnership(before: before, after: after, axItems: relevant) {
            ownershipCache[id] = info
        }
        cacheOwnWindows(after)
        publish(after)
        let now = ContinuousClock.now
        unresolvedSince = Dictionary(uniqueKeysWithValues: after
            .filter { ownershipCache[$0.windowID] == nil && !StaleWindowFilter.isCandidate($0) }
            .map { ($0.windowID, now) })
        if unresolvedSince.isEmpty {
            scheduledRetries = 0
        } else if OwnershipRefreshPolicy.shouldScheduleRetry(unresolved: unresolvedSince.count,
                                                             retriesSoFar: scheduledRetries) {
            scheduledRetries += 1
            FrostLog.scanner.notice("""
                \(self.unresolvedSince.count) window(s) still without an owner; reading again in \
                \(OwnershipRefreshPolicy.retryInterval, privacy: .public)
                """)
            scheduleRescan(after: OwnershipRefreshPolicy.retryInterval, refreshOwnership: true)
        }
    }

    /// Builds `items` from the ownership cache (dropping leftover windows of apps that quit) and discards
    /// cache entries for windows that are gone. `items` and `status` are only assigned when they change: every assignment
    /// notifies observers (the layout editor and the Frost Bar redraw), and most rescans find the menu bar as it was.
    private func publish(_ windows: [RawStatusWindow]) {
        let systemSlots = SystemItemRules.trailingSlots(windows, excluding: ownWindowIDs())
        let fresh = windows.map { window in
            let owner = ownershipCache[window.windowID]
            return MenuBarItem(windowID: window.windowID, frame: window.frame, isOnScreen: window.isOnScreen,
                               windowTitle: window.title, bundleID: owner?.bundleID, pid: owner?.pid,
                               axDescription: owner?.description, axTitle: owner?.title,
                               axIdentifier: owner?.identifier, identityKey: owner?.identityKey,
                               numberedIdentityKey: owner?.numberedIdentityKey,
                               occupiesSystemSlot: systemSlots.contains(window.windowID))
        }.filter { !StaleWindowFilter.isStale($0) }
        if fresh != items { items = fresh }
        let live = Set(windows.map(\.windowID))
        publishedWindowIDs = live
        ownershipCache = ownershipCache.filter { live.contains($0.key) }
        unresolvedSince = unresolvedSince.filter { live.contains($0.key) }
        let scanned: ScanStatus = windows.isEmpty ? .noWindows : .ok
        if scanned != status { status = scanned }
    }

    /// Assigns ownership of Frost's own windows directly (the AX read skips this process).
    private func cacheOwnWindows(_ windows: [RawStatusWindow]) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let own = ownWindowIDs()
        for window in windows where own.contains(window.windowID) && ownershipCache[window.windowID] == nil {
            ownershipCache[window.windowID] = AXItemInfo(bundleID: bundleID, pid: getpid(), frame: window.frame,
                                                         description: nil)
        }
    }

    /// The real windows on the active menu bar (`MenuBarDisplayResolver`); also updates `menuBarDisplay` /
    /// `replicaIconFrames`.
    private func menuBarWindows() -> [RawStatusWindow] {
        let displays = Self.currentDisplays()
        guard let resolution = MenuBarDisplayResolver.resolve(
            windows: StatusWindowParser.currentWindows(), displays: displays, mainDisplayID: CGMainDisplayID(),
            controls: controlFrames())
        else { return [] }
        if menuBarDisplay != resolution.display {
            if displays.count > 1 {
                let frame = NSStringFromRect(resolution.display.frame)
                FrostLog.scanner.notice("""
                    managing the menu bar of display \(resolution.display.id) \(frame, privacy: .public) \
                    (main display \(CGMainDisplayID()))
                    """)
            }
            menuBarDisplay = resolution.display
        }
        replicaIconFrames = resolution.replicaIcons
        if resolution.unresolved != lastUnresolved {
            // Log only on change (it shows up briefly during move / expand animations and should return to 0
            // once things settle).
            lastUnresolved = resolution.unresolved
            FrostLog.scanner.notice("""
                \(resolution.unresolved) status window(s) could not be told apart from other displays' replicas \
                (kept unless inside a same-height display)
                """)
        }
        return resolution.windows
    }

    /// All displays (CG coordinates) with their menu bar heights (`frame.maxY − visibleFrame.maxY`; 0 when
    /// the menu bar auto-hides). Don't use `NSStatusBar.system.thickness` (it returns 22).
    public static func currentDisplays() -> [MenuBarDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            return MenuBarDisplay(id: id, frame: CGDisplayBounds(id),
                                  menuBarHeight: max(0, screen.frame.maxY - screen.visibleFrame.maxY))
        }
    }

    private static func isProcessAlive(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid) != nil
    }
}
