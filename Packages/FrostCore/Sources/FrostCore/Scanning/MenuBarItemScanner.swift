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
/// display), and rescans automatically when apps launch or quit.
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

    @ObservationIgnored private var runningAppsObservation: NSKeyValueObservation?
    @ObservationIgnored private var pendingRescan: Task<Void, Never>?
    @ObservationIgnored private var pendingRefreshOwnership = false
    @ObservationIgnored private lazy var ownershipRefresher = RefreshCoalescer { [weak self] in
        await self?.performOwnershipRefresh()
    }

    public init() {}

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
        rescan()
        ownershipRefresher.refreshInBackground()
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

    /// Rescans the active menu bar's items (synchronous, cheap): reads only CGWindowList and reuses cached
    /// ownership. If any window needs a full AX read (a new window, or an unresolved one due for a retry),
    /// starts one in the background that updates `items` when it finishes.
    public func rescan() {
        let windows = menuBarWindows()
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
        await ownershipRefresher.refresh()
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
    /// cache entries for windows that are gone.
    private func publish(_ windows: [RawStatusWindow]) {
        items = windows.map { window in
            let owner = ownershipCache[window.windowID]
            return MenuBarItem(windowID: window.windowID, frame: window.frame, isOnScreen: window.isOnScreen,
                               windowTitle: window.title, bundleID: owner?.bundleID, pid: owner?.pid,
                               axDescription: owner?.description)
        }.filter { !StaleWindowFilter.isStale($0) }
        let live = Set(windows.map(\.windowID))
        ownershipCache = ownershipCache.filter { live.contains($0.key) }
        unresolvedSince = unresolvedSince.filter { live.contains($0.key) }
        status = windows.isEmpty ? .noWindows : .ok
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
