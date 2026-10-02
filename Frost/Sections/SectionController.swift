import AppKit
import FrostCore
import Observation

/// Manages Frost's three status items (left to right: `[AH separator] [H separator] [Frost icon]`) and hides/shows sections.
///
/// - collapsed: H and AH are both `length = 10_000` (clamped by the system to a 5016 pt window), pushing everything to
///   their left off screen.
/// - expanded: H is 0 (narrowed further to 1 pt with a constraint trick); AH stays 10_000.
/// - expandedAll: H and AH are both 0 (no line shown; the AH line only appears in the layout editor).
/// - isEditing: overrides the above; H and AH both show as thin vertical lines (`length = 8`).
@Observable
@MainActor
final class SectionController {
    typealias State = SectionState

    private(set) var state: State = .collapsed
    private(set) var isEditing = false
    /// Temporarily collapsed during editing to perform a move (see `whileCollapsedForMove`).
    @ObservationIgnored private var isSuspendedForMove = false
    /// A temporary expansion (Frost Bar live refresh) in progress: state changes requested meanwhile are recorded
    /// and applied by `restore` (see `TemporaryExpansion`).
    @ObservationIgnored private var temporaryExpansion: TemporaryExpansion?

    /// Set by AppModel; used for navigation callbacks (Settings, Frost Bar).
    @ObservationIgnored weak var model: AppModel?

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let permissions: PermissionsService
    @ObservationIgnored private let scanner: MenuBarItemScanner

    @ObservationIgnored private var iconItem: NSStatusItem?
    @ObservationIgnored private var iconImageView: NSImageView?
    /// A dot on the Frost icon while an update found by a scheduled check awaits the user (`UpdateController`).
    @ObservationIgnored private var updateBadge: NSView?
    @ObservationIgnored private var hidden: SeparatorItem?
    @ObservationIgnored private var alwaysHidden: SeparatorItem?

    @ObservationIgnored private var rehideTask: Task<Void, Never>?
    /// Mouse monitors (global + local) that collapse immediately on an outside click while expanded inline.
    @ObservationIgnored private var outsideClickMonitors: [Any] = []
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    /// The control item windows located last time. Window IDs don't change for the life of the process, so they're
    /// reused as long as they're still in the scan results.
    @ObservationIgnored private var locatedControls: FrostControlWindows?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    /// The display (active menu bar) the Frost icon's real window was last on.
    @ObservationIgnored private var iconDisplayID: CGDirectDisplayID?
    /// Multiple displays: clicks on a snowflake replica on another display that never reached the button
    /// (see `ReplicaClickDetector`).
    @ObservationIgnored private var replicaClicks = ReplicaClickDetector()
    @ObservationIgnored private var replicaClickMonitors: [Any] = []
    @ObservationIgnored private var replicaClickTask: Task<Void, Never>?
    @ObservationIgnored private var screenParametersObserver: NSObjectProtocol?
    @ObservationIgnored private var displayRescanTask: Task<Void, Never>?
    /// Environment variable `FROST_TEST_DROP_REPLICA_CLICKS=1` (VM testing only): drops replica clicks the system
    /// redelivers to the button, simulating a real Mac where the first click on a replica isn't delivered, to exercise
    /// the fallback path (the VM's virtual display redelivers, so it can't reproduce this otherwise).
    #if DEBUG
    private static let dropRedeliveredReplicaClicks =
        ProcessInfo.processInfo.environment["FROST_TEST_DROP_REPLICA_CLICKS"] == "1"
    #else
    private static let dropRedeliveredReplicaClicks = false
    #endif

    init(preferences: Preferences, permissions: PermissionsService, scanner: MenuBarItemScanner) {
        self.preferences = preferences
        self.permissions = permissions
        self.scanner = scanner
    }

    // MARK: - Installation

    static let iconAutosaveName = FrostControlLocator.iconTitle
    static let hiddenAutosaveName = FrostControlLocator.hiddenSeparatorTitle
    static let alwaysHiddenAutosaveName = FrostControlLocator.alwaysHiddenSeparatorTitle

    /// Preferred Position seeds (smaller values are further right). Written only when the key doesn't exist:
    /// the icon sits right next to Control Center; existing third-party icons with a Preferred Position land between
    /// H and AH (the Hidden section).
    /// AH can't get a small value, or every existing icon would end up in Always Hidden. Icons without a Preferred
    /// Position (never ⌘-dragged, i.e. most of them) sort left of AH no matter its value: on the first run
    /// NewItemPlacer moves them to Hidden.
    static let seeds: [(name: String, position: Double)] = [
        (iconAutosaveName, 0), (hiddenAutosaveName, 1), (alwaysHiddenAutosaveName, 10_000),
    ]

    /// Symbol configuration for the snowflake: same size and weight as system menu bar glyphs (Wi-Fi, Control Center).
    static let iconSymbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)

    func install() {
        guard iconItem == nil else { return }
        let defaults = UserDefaults.standard
        for seed in Self.seeds {
            let key = "NSStatusItem Preferred Position \(seed.name)"
            guard defaults.object(forKey: key) == nil else { continue }
            defaults.set(seed.position, forKey: key)
            // First run: existing icons without a Preferred Position are placed left of AH (Always Hidden);
            // NewItemPlacer moves them to Hidden once all permissions are granted (possibly only after granting
            // and relaunching, hence persisted).
            if seed.name == Self.alwaysHiddenAutosaveName { NewItemPlacer.markFirstRun(defaults: defaults) }
        }

        // Creation order icon -> H -> AH (created earlier = further right). Never call removeStatusItem on quit:
        // it deletes the Preferred Position.
        let icon = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        icon.autosaveName = Self.iconAutosaveName
        icon.isVisible = true
        if let button = icon.button {
            button.setAccessibilityLabel("Frost")
            button.target = self
            button.action = #selector(iconClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // NSButton doesn't expose its internal image view; add our own to control symbol size and centering.
            let imageView = NSImageView()
            imageView.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Frost")
            // The status bar button configures a `button.image` symbol to the menu bar glyph size, but not our own
            // image view: unconfigured, the snowflake looks noticeably smaller and thinner than neighboring Wi-Fi or
            // third-party icons. (SF Symbols are template images and follow the menu bar's appearance.)
            imageView.symbolConfiguration = Self.iconSymbolConfiguration
            imageView.imageScaling = .scaleNone
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.setAccessibilityElement(false)
            button.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
            iconImageView = imageView
            let badge = NSView()
            badge.wantsLayer = true
            badge.layer?.cornerRadius = Self.updateBadgeSize / 2
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.isHidden = true
            badge.setAccessibilityElement(false)
            button.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.widthAnchor.constraint(equalToConstant: Self.updateBadgeSize),
                badge.heightAnchor.constraint(equalToConstant: Self.updateBadgeSize),
                badge.centerXAnchor.constraint(equalTo: imageView.trailingAnchor),
                badge.centerYAnchor.constraint(equalTo: imageView.topAnchor, constant: 1),
            ])
            updateBadge = badge
        }
        iconItem = icon
        if let window = icon.button?.window {
            // When the active menu bar moves to another display, the real window moves with it: rescan right away
            // (both the frames in `items` and their display changed).
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let screen = self.iconWindow?.screen else { return }
                    let id = Self.displayID(of: screen)
                    // Also fires when the status item is created (no screen -> main display): only record real
                    // display changes.
                    defer { self.iconDisplayID = id }
                    guard let previous = self.iconDisplayID, previous != id else { return }
                    FrostLog.sections.notice(
                        "the Frost icon moved from display \(previous) to \(id) (active menu bar changed); rescanning")
                    self.scanner.scheduleRescan(after: .milliseconds(100))
                }
            }
        }

        updateReplicaClickMonitors()
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateReplicaClickMonitors()
                self?.rescanAfterDisplayChange()
            }
        }

        hidden = SeparatorItem(autosaveName: Self.hiddenAutosaveName)
        alwaysHidden = SeparatorItem(autosaveName: Self.alwaysHiddenAutosaveName)
        applyLengths()
        settleAndRescan()
        trackUpdateReminder()
    }

    // MARK: - Update reminder

    static let updateBadgeSize: CGFloat = 6

    /// Shows the update badge (and says so to VoiceOver) while `UpdateController.pendingUpdateVersion` is set.
    private func trackUpdateReminder() {
        let pending = withObservationTracking {
            model?.updates.pendingUpdateVersion != nil
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.trackUpdateReminder() }
        }
        updateBadge?.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        updateBadge?.isHidden = !pending
        iconItem?.button?.setAccessibilityLabel(pending
            ? String(localized: "Frost, update available",
                     comment: "Accessibility label of the Frost menu bar icon while an update is waiting to be installed")
            : "Frost")
    }

    // MARK: - Control item windows

    /// Window IDs of Frost's three control items in the scan results (`button.window.windowNumber` is not a CG window ID).
    /// Matched by button window frame (converted to CG coordinates), falling back to the window title; returns a
    /// value only if all three are found.
    var controlWindows: FrostControlWindows? {
        let items = scanner.items
        if let locatedControls, locatedControls.all.isSubset(of: Set(items.map(\.windowID))) {
            return locatedControls
        }
        let located = FrostControlLocator.locate(
            in: items,
            iconFrame: iconItem?.button?.window.map { Self.cgFrame(of: $0.frame) },
            hiddenFrame: hidden?.cgFrame,
            alwaysHiddenFrame: alwaysHidden?.cgFrame)
        locatedControls = located
        return located
    }

    /// CG frames of the real windows of Frost's three control items (the scanner uses them to find the display with the
    /// active menu bar and to tell replicas on other displays apart).
    var controlFrames: FrostControlFrames? {
        guard iconItem != nil else { return nil }
        return FrostControlFrames(icon: iconItem?.button?.window.map { Self.cgFrame(of: $0.frame) },
                                  hidden: hidden?.cgFrame, alwaysHidden: alwaysHidden?.cgFrame)
    }

    /// The status bar window holding the Frost icon button (the Frost Bar positions itself by it and checks whether a
    /// click landed on the icon).
    ///
    /// Multiple displays: this is the **real** window, always on the display with the active menu bar (it moves to
    /// whichever display's menu bar the user clicks or focuses; other displays show replicas, see
    /// `MenuBarDisplayResolver`). Clicking the snowflake on a secondary display first moves the real window there, then
    /// (in a VM) redelivers the click to it, so the Frost Bar opens under the clicked snowflake. On a real Mac the click
    /// may not reach the button (first click does nothing); `ReplicaClickDetector` detects and replays it
    /// (`replicaClickMonitors`).
    var iconWindow: NSWindow? { iconItem?.button?.window }

    /// AppKit (bottom-left origin) -> CG (top-left origin): `y = primary display frame.maxY - frame.maxY`. The same
    /// formula converts back.
    static func cgFrame(of appKitFrame: CGRect) -> CGRect {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: appKitFrame.minX, y: primaryMaxY - appKitFrame.maxY,
                      width: appKitFrame.width, height: appKitFrame.height)
    }

    /// CG -> AppKit (inverse of `cgFrame(of:)`, same formula).
    static func appKitFrame(ofCG cgFrame: CGRect) -> CGRect { self.cgFrame(of: cgFrame) }

    // MARK: - State

    /// Switches to `newState` (while editing, only records it without changing the appearance). During a temporary
    /// expansion only records the request: `restore` ends in it, so the freeze frame is removed only once the
    /// requested state is confirmed.
    func setState(_ newState: State) {
        if temporaryExpansion != nil {
            temporaryExpansion?.request(newState)
            FrostLog.sections.notice("state \(newState.rawValue) requested during a temporary expansion; applied when it ends")
            return
        }
        state = newState
        guard !isEditing else { return }
        applyLengths()
        settleAndRescan()
        if newState == .collapsed { cancelAutoRehide() } else { armAutoRehide() }
    }

    func beginEditing() {
        cancelAutoRehide()
        isEditing = true
        applyLengths()
        settleAndRescan()
    }

    /// Ends editing and collapses. If a move transaction is in progress, the caller (LayoutEditorModel) should await it first.
    func endEditing() {
        isEditing = false
        setState(.collapsed)
    }

    /// Runs `body` with the menu bar temporarily collapsed (separators pushed out) during editing, then restores the
    /// editing state; both switches wait for frames to settle and rescan.
    ///
    /// On a crowded notched display, items that don't fit in editing state are tucked under the notch, so their x doesn't
    /// reflect the real order and moves can't be verified (on a real Mac they also fail silently). Collapsed, everything
    /// to the left is pushed off screen together, the order is reliable, and moves routed by window ID complete and
    /// verify normally. Outside editing, runs `body` directly.
    func whileCollapsedForMove<T>(_ body: () async throws -> T) async rethrows -> T {
        guard isEditing, !isSuspendedForMove else { return try await body() }
        isSuspendedForMove = true
        applyLengths()
        await waitForSettle()
        scanner.rescan()
        do {
            let result = try await body()
            await resumeEditingAfterMove()
            return result
        } catch {
            await resumeEditingAfterMove()
            throw error
        }
    }

    private func resumeEditingAfterMove() async {
        isSuspendedForMove = false
        applyLengths()
        await waitForSettle()
        scanner.rescan()
    }

    /// Temporarily expands to at least `target` and waits for frames to settle (fast detection via `waitForFastSettle`,
    /// used by the Frost Bar's live refresh under the freeze frame, so faster is better). Returns the previous state for
    /// `restore(_:)` and whether the change was confirmed applied and settled (false on timeout: items aren't on screen
    /// yet and the caller shouldn't capture). Doesn't arm auto-rehide. While editing, or if already expanded enough,
    /// changes nothing (`settled` is true).
    func temporarilyExpand(_ target: State) async -> (previous: State, settled: Bool) {
        let original = state
        guard !isEditing, temporaryExpansion == nil, target > original else { return (original, true) }
        cancelAutoRehide()
        let baseline = statusFrames()
        temporaryExpansion = TemporaryExpansion(prior: original)
        state = target
        applyLengths()
        let settled = await waitForFastSettle(baseline: baseline, timeout: Self.expandSettleTimeout)
        scanner.rescan()
        return (original, settled)
    }

    /// Ends the temporary expansion and waits to settle; returns whether the final state was confirmed applied. The
    /// final state is `previous` (the state before `temporarilyExpand`), unless the user asked for another one
    /// meanwhile (e.g. clicked the Frost icon on a display that expands in the menu bar): then that one, so their click
    /// is neither lost nor undone. Collapsing occasionally takes a few hundred ms to apply (about 0.5 s measured in a
    /// VM, with the separators still at expanded length meanwhile), and the freeze frame must stay until then, so the
    /// timeout is longer than expanding (the Frost Bar passes as much as its freeze frame allows).
    @discardableResult
    func restore(_ previous: State, timeout: Duration = SectionController.restoreSettleTimeout) async -> Bool {
        let expansion = temporaryExpansion
        temporaryExpansion = nil
        let target = expansion?.finalState ?? previous
        if let expansion, expansion.requested != nil {
            FrostLog.sections.notice("""
                ending a temporary expansion in state \(target.rawValue) requested meanwhile \
                (was \(expansion.prior.rawValue))
                """)
        }
        guard !isEditing else {
            state = target
            return true
        }
        guard target != state else {
            // Already in the final state (the user asked for the temporary one): nothing to wait for.
            if expansion != nil, target != .collapsed { armAutoRehide() }
            return true
        }
        let baseline = statusFrames()
        state = target
        applyLengths()
        if target != .collapsed { armAutoRehide() }
        let settled = await waitForFastSettle(baseline: baseline, timeout: timeout)
        scanner.rescan()
        return settled
    }

    static let expandSettleTimeout: Duration = .milliseconds(500)
    static let restoreSettleTimeout: Duration = .milliseconds(1500)

    private func applyLengths() {
        guard let hidden, let alwaysHidden else { return }
        if isEditing && isSuspendedForMove {
            hidden.mode = .pushOut
            alwaysHidden.mode = .pushOut
            return
        }
        if isEditing {
            hidden.mode = .line
            alwaysHidden.mode = .line
            return
        }
        switch state {
        case .collapsed:
            hidden.mode = .pushOut
            alwaysHidden.mode = .pushOut
        case .expanded:
            hidden.mode = .zero
            alwaysHidden.mode = .pushOut
        case .expandedAll:
            hidden.mode = .zero
            alwaysHidden.mode = .zero
        }
    }

    // MARK: - Waiting to settle

    /// Polls the CG frames of Frost's control item windows every 50 ms until two polls match (min 100 ms, timeout 500 ms).
    /// Measured: a length change applies after 55-61 ms and settles after 108-118 ms. To avoid declaring it settled
    /// before the change applies, the snapshot must also differ from the pre-change baseline before 250 ms. Only Frost's
    /// own windows are checked: other apps' icons may keep changing (width follows content), so "two matching polls"
    /// might never happen; items pushed around update in the same layout pass as the separators.
    func waitForSettle(baseline: [CGWindowID: CGRect]? = nil) async {
        let clock = ContinuousClock()
        let start = clock.now
        let baseline = baseline ?? statusFrames()
        var previous: [CGWindowID: CGRect]?
        while clock.now - start < .milliseconds(500) {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            let current = statusFrames()
            let elapsed = clock.now - start
            if elapsed >= .milliseconds(100), current == previous,
               current != baseline || elapsed >= .milliseconds(250) {
                return
            }
            previous = current
        }
    }

    /// Fast settle detection: polls the control item frames about every 16 ms and returns true once the change has
    /// applied (differs from `baseline`) and two polls match (`SettleDetector`), with no minimum wait; returns false if
    /// not confirmed within `timeout`. Frames are also checked around captures (`ItemImageCapturer` recaptures items
    /// that are still moving).
    func waitForFastSettle(baseline: [CGWindowID: CGRect], timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var detector = SettleDetector(baseline: baseline)
        while clock.now < deadline {
            do { try await Task.sleep(for: Self.fastSettlePoll) } catch { return false }
            if detector.observe(statusFrames()) { return true }
        }
        FrostLog.sections.error("the menu bar did not settle within \(timeout, privacy: .public) after changing sections")
        return false
    }

    static let fastSettlePoll: Duration = .milliseconds(16)

    /// CG frames of Frost's control item windows; before the controls are located, all status windows on the scanned
    /// menu bar row (the display with the active menu bar).
    private func statusFrames() -> [CGWindowID: CGRect] {
        let windows: [RawStatusWindow]
        if let ids = locatedControls?.all {
            windows = StatusWindowParser.windows(withIDs: ids)
        } else {
            let row = scanner.menuBarDisplay?.frame ?? CGDisplayBounds(CGMainDisplayID())
            windows = StatusWindowParser.currentWindows().filter { abs($0.frame.minY - row.minY) < 1 }
        }
        return Dictionary(windows.map { ($0.windowID, $0.frame) }, uniquingKeysWith: { a, _ in a })
    }

    /// After a state change, waits to settle and then rescans so `scanner.items` (and `AppModel.layout`) reflect the
    /// new positions.
    private func settleAndRescan() {
        let baseline = statusFrames()
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            await self?.waitForSettle(baseline: baseline)
            guard !Task.isCancelled, let self else { return }
            self.scanner.rescan()
            // Expanded inline, hidden items are on screen: capture them to keep the image cache (incl. disk) fresh.
            if self.state != .collapsed, !self.isEditing { self.model?.captureNaturallyVisibleItems() }
        }
    }

    // MARK: - Auto-rehide

    private func armAutoRehide() {
        cancelAutoRehide()
        guard preferences.autoRehide, !isEditing else { return }
        let delay = preferences.autoRehideDelay
        rehideTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            // Don't collapse while a menu is open (e.g. the user is in the menu of a just-revealed icon) or the
            // mouse is in the menu bar: check again later.
            while self?.shouldDeferAutoRehide == true {
                do { try await Task.sleep(for: Self.autoRehideRecheck) } catch { return }
            }
            guard let self, !self.isEditing, self.state != .collapsed else { return }
            self.setState(.collapsed)
        }
        // Clicks in other apps.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            guard !SyntheticEvents.isPostedByFrost(event) else { return }
            MainActor.assumeIsolated { self?.outsideClick(at: NSEvent.mouseLocation) }
        }) {
            outsideClickMonitors.append(global)
        }
        // Clicks in Frost's own windows (Settings, onboarding): global monitors don't receive this app's events. Frost's
        // status items (snowflake, separators) are in the menu bar and excluded by `outsideClick`; clicking the
        // snowflake toggles via `handleIconClick`.
        if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            guard !SyntheticEvents.isPostedByFrost(event) else { return event }
            MainActor.assumeIsolated {
                let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation
                self?.outsideClick(at: point, in: event.window)
            }
            return event
        }) {
            outsideClickMonitors.append(local)
        }
    }

    /// A click outside the menu bar (AppKit global coordinates): collapse. `window` is the Frost window of a local
    /// event (status item windows don't count as outside).
    private func outsideClick(at point: NSPoint, in window: NSWindow? = nil) {
        guard !isEditing, state != .collapsed, !isInMenuBar(point) else { return }
        if let window, window.className.contains("StatusBar") { return }
        setState(.collapsed)
    }

    private static let autoRehideRecheck: Duration = .seconds(2)

    private var shouldDeferAutoRehide: Bool {
        ItemClicker.isMenuOnScreen() || isInMenuBar(NSEvent.mouseLocation)
    }

    private func cancelAutoRehide() {
        rehideTask?.cancel()
        rehideTask = nil
        for monitor in outsideClickMonitors { NSEvent.removeMonitor(monitor) }
        outsideClickMonitors.removeAll()
    }

    /// Whether a point (AppKit global coordinates) is inside the menu bar of its screen. The menu bar height is computed
    /// from the screen (`frame.maxY - visibleFrame.maxY`; 39 on notched displays), not `NSStatusBar.system.thickness`
    /// (which returns 22).
    private func isInMenuBar(_ point: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) })
        else { return false }
        return point.y >= screen.frame.maxY - menuBarHeight(of: screen)
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func menuBarHeight(of screen: NSScreen) -> CGFloat {
        let height = screen.frame.maxY - screen.visibleFrame.maxY
        if height > 0 { return height }
        // With an auto-hiding menu bar, visibleFrame doesn't exclude it: use the Frost icon window's height instead.
        return iconItem?.button?.window?.frame.height ?? 24
    }

    // MARK: - Frost icon

    @objc private func iconClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if Self.dropRedeliveredReplicaClicks, replicaClicks.hasPendingClick {
            FrostLog.sections.notice("test: dropping the redelivered click on the replica (FROST_TEST_DROP_REPLICA_CLICKS)")
            return
        }
        guard replicaClicks.actionReceived(eventTime: event.timestamp) else {
            // This click was already replayed by `fireReplicaClickIfDue` (the system delivered it to the button late):
            // don't toggle again.
            FrostLog.sections.notice("ignoring a late Frost icon action for a replica click that was already handled")
            return
        }
        let isContextClick = event.type == .rightMouseUp
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
        handleIconClick(context: isContextClick, option: event.modifierFlags.contains(.option),
                        screen: clickedScreen(for: event))
    }

    /// The display a click on the Frost icon happened on. After a click on another display's replica, the system can
    /// deliver the click to the button before it moves the real window to that display (seen in the VM during a
    /// Frost Bar live refresh round), so the window's screen may still be the previous one; the pointer is where the
    /// user clicked. Non-mouse actions (e.g. VoiceOver) use the window's screen.
    private func clickedScreen(for event: NSEvent) -> NSScreen? {
        let windowScreen = iconItem?.button?.window?.screen
        guard [.leftMouseUp, .rightMouseUp, .leftMouseDown, .rightMouseDown].contains(event.type) else {
            return windowScreen
        }
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? windowScreen
    }

    /// Right-click / Control-click -> menu; click -> Frost Bar (per the effective display mode of `screen`, the display
    /// clicked on) or toggle collapsed <-> expanded; with ⌥ -> expandedAll.
    private func handleIconClick(context: Bool, option: Bool, screen: NSScreen?) {
        if context {
            showMenu()
            return
        }
        guard !isEditing else { return }
        let mode = preferences.effectiveDisplayMode(for: screen, permissionsGranted: permissions.allGranted)
        if mode == .frostBar {
            model?.toggleFrostBar(option)
            return
        }
        // During a temporary expansion (the Frost Bar's live refresh, possibly on another display) the real state is
        // the temporary one; judge the click against the state the user sees and let `restore` apply it.
        if temporaryExpansion != nil {
            temporaryExpansion?.iconClicked(option: option)
            FrostLog.sections.notice("Frost icon clicked during a temporary expansion; applied when it ends")
            return
        }
        setState(state.afterIconClick(option: option))
    }

    private func showMenu() {
        guard let iconItem, let button = iconItem.button else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let settings = NSMenuItem(
            title: String(localized: "Settings…", comment: "Frost icon context menu item"),
            action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        // Every item gets its own symbol so the titles line up (the system adds one automatically only to some
        // standard items, and only for some languages).
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)
        let update: NSMenuItem
        if model?.updates.pendingUpdateVersion != nil {
            // A scheduled check found an update (gentle reminder): this brings its window to the front.
            update = NSMenuItem(
                title: String(localized: "Update Available…",
                              comment: "Frost icon context menu item shown when an update is waiting to be installed"),
                action: #selector(checkForUpdates), keyEquivalent: "")
            update.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        } else {
            update = NSMenuItem(
                title: String(localized: "Check for Updates…", comment: "Frost icon context menu item"),
                action: #selector(checkForUpdates), keyEquivalent: "")
            update.isEnabled = model?.updates.canCheckForUpdates ?? false
            update.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        }
        update.target = self
        menu.addItem(update)
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: String(localized: "Quit Frost", comment: "Frost icon context menu item"),
            action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quit)
        iconItem.menu = menu
        button.performClick(nil)
        iconItem.menu = nil
    }

    /// While Frost posts a move's ⌘-drag (its mouse-down physically lands on the Frost icon, see `ItemMover`), the
    /// icon must not show a pressed highlight: the user clicked a tile in the Frost Bar, not the snowflake. Restored a
    /// little after the move, once the routed mouse-up has been handled too. The user's own clicks on the icon still
    /// work meanwhile (only the highlight is off).
    func suppressIconHighlight(_ suppressed: Bool) {
        guard let button = iconItem?.button, let cell = button.cell as? NSButtonCell else { return }
        highlightRestoreTask?.cancel()
        highlightRestoreTask = nil
        if suppressed {
            if savedHighlightsBy == nil { savedHighlightsBy = cell.highlightsBy }
            cell.highlightsBy = []
            button.highlight(false)
            return
        }
        highlightRestoreTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.highlightRestoreDelay) } catch { return }
            guard let self, let saved = self.savedHighlightsBy else { return }
            self.savedHighlightsBy = nil
            self.highlightRestoreTask = nil
            cell.highlightsBy = saved
        }
    }

    @ObservationIgnored private var savedHighlightsBy: NSCell.StyleMask?
    @ObservationIgnored private var highlightRestoreTask: Task<Void, Never>?
    private static let highlightRestoreDelay: Duration = .milliseconds(300)

    @objc private func openSettings() { model?.openSettings() }

    @objc private func checkForUpdates() { model?.updates.checkForUpdates() }

    // MARK: - Snowflake replicas on other displays

    /// A display was connected, disconnected or rearranged: the scanned menu bar (`scanner.menuBarDisplay`) and the
    /// replica frames (`scanner.replicaIconFrames`, used to recognize clicks on a snowflake replica) must be fresh, or
    /// the first click on a newly connected display's snowflake is missed. The new display's menu bar windows show up
    /// shortly after the notification, so rescan now and again a little later, then read ownership once more.
    private func rescanAfterDisplayChange() {
        scanner.rescan()
        displayRescanTask?.cancel()
        displayRescanTask = Task { [weak self] in
            for delay: Duration in [.milliseconds(300), .seconds(1)] {
                do { try await Task.sleep(for: delay) } catch { return }
                self?.scanner.rescan()
            }
            self?.scanner.scheduleRescan(after: .zero, refreshOwnership: true)
        }
        FrostLog.sections.notice("display configuration changed (\(NSScreen.screens.count) display(s)); rescanning")
    }

    /// With more than one display, monitors the mouse (global: events on a replica belong to another window; local:
    /// events the system redelivers to the Frost icon); removes the monitors with a single display.
    private func updateReplicaClickMonitors() {
        let needed = NSScreen.screens.count > 1
        if needed, replicaClickMonitors.isEmpty {
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
            if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
                MainActor.assumeIsolated { self?.replicaMouseEvent(event, isLocal: false) }
            }) {
                replicaClickMonitors.append(global)
            }
            if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
                MainActor.assumeIsolated { self?.replicaMouseEvent(event, isLocal: true) }
                return event
            }) {
                replicaClickMonitors.append(local)
            }
        } else if !needed, !replicaClickMonitors.isEmpty {
            for monitor in replicaClickMonitors { NSEvent.removeMonitor(monitor) }
            replicaClickMonitors.removeAll()
            replicaClickTask?.cancel()
            replicaClickTask = nil
            replicaClicks = ReplicaClickDetector()
        }
    }

    private func replicaMouseEvent(_ event: NSEvent, isLocal: Bool) {
        let button: ReplicaClickDetector.Button
        switch event.type {
        case .leftMouseDown, .leftMouseUp: button = .left
        case .rightMouseDown, .rightMouseUp: button = .right
        default: return
        }
        let isDown = event.type == .leftMouseDown || event.type == .rightMouseDown
        if isDown {
            if isLocal {
                guard event.window === iconWindow, !Self.dropRedeliveredReplicaClicks else { return }
                replicaClicks.deliveredMouseDown(time: event.timestamp)
                return
            }
            // Global monitor events have no window, so `locationInWindow` is in screen coordinates (AppKit, bottom-left origin).
            let point = OutsideClickDismissal.cgPoint(fromAppKit: event.locationInWindow,
                                                      primaryScreenMaxY: NSScreen.screens.first?.frame.maxY ?? 0)
            let hit = replicaClicks.globalMouseDown(at: point, time: event.timestamp, button: button,
                                                    control: event.modifierFlags.contains(.control),
                                                    option: event.modifierFlags.contains(.option),
                                                    replicaIcons: scanner.replicaIconFrames)
            if hit {
                let active = iconDisplayID ?? 0
                FrostLog.sections.notice("mouse down on a Frost icon replica at (\(point.x), \(point.y)); active display \(active)")
            }
            return
        }
        guard replicaClicks.hasPendingClick else { return }
        replicaClicks.mouseUp(button: button, time: event.timestamp)
        replicaClickTask?.cancel()
        replicaClickTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(ReplicaClickDetector.grace) + .milliseconds(20)) } catch { return }
            await self?.fireReplicaClickIfDue()
        }
    }

    /// The click didn't reach the button within `grace` of mouse-up: wait (up to 0.5 s) for the real window to move
    /// to the clicked display, then handle it as a click.
    private func fireReplicaClickIfDue() async {
        guard let click = replicaClicks.due(now: ProcessInfo.processInfo.systemUptime) else { return }
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(500)
        while iconWindow?.screen.map(Self.displayID(of:)) != click.displayID, clock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
        }
        let current = iconWindow?.screen.map(Self.displayID(of:)) ?? 0
        FrostLog.sections.notice(
            "click on the Frost icon replica on display \(click.displayID) did not reach the button; handling it (icon on display \(current))")
        let screen = NSScreen.screens.first { Self.displayID(of: $0) == click.displayID } ?? iconWindow?.screen
        handleIconClick(context: click.isContextClick, option: click.option, screen: screen)
    }

    @objc private func quit() { NSApp.terminate(nil) }

}

/// The H / AH separator status items.
@MainActor
private final class SeparatorItem {
    enum Mode: Equatable {
        /// `length = 10_000`: pushes everything to the left off screen.
        case pushOut
        /// `length = 0`, narrowed to 1 pt where possible (the system leaves a 16 pt gap by default).
        case zero
        /// Thin vertical line in the layout editor (`length = 8`).
        case line
    }

    static let pushOutLength: CGFloat = 10_000
    static let lineLength: CGFloat = 8

    let item: NSStatusItem
    var mode: Mode? {
        didSet { if mode != oldValue || mode == .zero { apply() } }
    }

    /// Ice's trick: the window's content view has the constraint
    /// `NSStatusBarContentView.width == button.superview.width + 16`,
    /// which leaves a 16 pt gap even at length 0. Deactivate it and set the window content width to 1. If it can't
    /// be found, keep the 16 pt.
    private var gapConstraint: NSLayoutConstraint?
    private var resizeObserver: NSObjectProtocol?
    private var reapplyTimes: [ContinuousClock.Instant] = []
    private var gaveUpNarrowing = false

    init(autosaveName: String) {
        item = NSStatusBar.system.statusItem(withLength: Self.pushOutLength)
        item.autosaveName = autosaveName
        item.isVisible = true
        if let button = item.button {
            button.setAccessibilityLabel(
                String(localized: "Frost Separator", comment: "Accessibility label of Frost's section separator status items"))
            (button.cell as? NSButtonCell)?.highlightsBy = []
        }
        if let window = item.button?.window {
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowDidResize() }
            }
        }
    }

    /// The button window's frame in CG coordinates.
    var cgFrame: CGRect? {
        item.button?.window.map { SectionController.cgFrame(of: $0.frame) }
    }

    private func apply() {
        guard let mode, let button = item.button else { return }
        switch mode {
        case .pushOut:
            restoreGap()
            button.image = nil
            button.isEnabled = false
            item.length = Self.pushOutLength
        case .line:
            restoreGap()
            button.image = Self.lineImage
            // Keep enabled, or the line is drawn in the faded disabled color; with no action, clicks do nothing.
            button.isEnabled = true
            item.length = Self.lineLength
        case .zero:
            button.image = nil
            button.isEnabled = false
            item.length = 0
            narrow()
        }
    }

    private func narrow() {
        guard !gaveUpNarrowing, let button = item.button, let window = button.window else { return }
        if gapConstraint == nil {
            gapConstraint = window.contentView?.constraintsAffectingLayout(for: .horizontal)
                .first { $0.secondItem === button.superview }
        }
        guard let gapConstraint else { return }
        gapConstraint.isActive = false
        var size = window.frame.size
        size.width = 1
        window.setContentSize(size)
    }

    private func restoreGap() {
        guard let gapConstraint, !gapConstraint.isActive else { return }
        gapConstraint.isActive = true
    }

    /// The system may restore the window to 16 pt when it re-lays out the menu bar: narrow it again in `.zero`.
    /// If the system reverts it more than 10 times within 1 second, give up narrowing (keep 16 pt) to avoid fighting it.
    private func windowDidResize() {
        guard mode == .zero, !gaveUpNarrowing, let width = item.button?.window?.frame.width, width > 1 else { return }
        let now = ContinuousClock.now
        reapplyTimes = reapplyTimes.filter { now - $0 < .seconds(1) } + [now]
        if reapplyTimes.count > 10 {
            gaveUpNarrowing = true
            restoreGap()
            return
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.mode == .zero else { return }
                self.narrow()
            }
        }
    }

    /// 1 pt x 14 pt rounded vertical line whose color follows the appearance (`secondaryLabelColor`).
    static let lineImage: NSImage = {
        let image = NSImage(size: NSSize(width: 1, height: 14), flipped: false) { rect in
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 0.5, yRadius: 0.5).fill()
            return true
        }
        image.isTemplate = false
        return image
    }()
}
