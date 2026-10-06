import AppKit
import FrostCore
import Observation

/// State and actions of the layout editor. Owned by the Settings window (same lifetime); views only read the derived
/// `LayoutEditorState`.
///
/// The editor is "active" when the Settings window is visible (open, not minimized, Frost not hidden, the window not
/// entirely covered, and the user at the Mac; see `SettingsWindowController`) **and** the Layout tab is selected.
/// While active:
/// - the menu bar is in editing state (all sections expanded, both separators shown as lines); permissions are polled
///   every second;
/// - every 2 s a cheap `rescan()` (no forced AX read) refreshes the layout and captures only the on-screen items in
///   `capturer.missing(...)`; every 10 s all visible items are recaptured (icon contents may change);
/// - a full refresh (forced AX ownership read + recapture of all visible items, see `fullRefresh()`) runs automatically:
///   once after entering editing and settling; once when the Settings window becomes key again (user switches back
///   from another app); every 10 s, but only if some item has an unknown owner or is on screen without an image; and
///   every 3 s as a retry when the menu bar can't be read or the separators can't be found.
///
/// On deactivation, if a move transaction is in progress, editing ends (menu bar collapses) only after it finishes;
/// after deactivation, late async completions no longer modify state.
@Observable
@MainActor
final class LayoutEditorModel {
    enum Phase: Equatable {
        case needsPermission
        case loading
        /// `scanner.status == .noWindows`: CGWindowList returned no menu bar windows.
        case noWindows
        /// Frost's own separators can't be found (`AppModel.layout` is empty).
        case controlsMissing
        case ready

        /// The menu bar can't be read / the separators can't be found: the editor retries automatically.
        var isFailure: Bool { self == .noWindows || self == .controlsMissing }
    }

    @ObservationIgnored private let model: AppModel

    /// Items being moved or queued to move (tiles show progress).
    private(set) var pending: Set<CGWindowID> = []
    /// Set when a move fails; cleared after 3 seconds.
    private(set) var errorMessage: String?
    /// The session of the full refresh in progress (nil = none). Never two concurrent full refreshes in one session.
    private var fullRefreshSession: Int?
    /// A move transaction (Frost Bar click forwarding / move back) was running at activation: editing starts only
    /// after it ends, with a loading state meanwhile.
    private(set) var isWaitingForMover = false

    /// The last displayed layout (before editing, a snapshot taken while collapsed); keeps off-screen items in their
    /// sections, see `LayoutReconciler`.
    private var previous: MenuBarLayout = [:]
    /// After a drop and before the move completes, dragged items are shown optimistically at their destination
    /// (in drop order, including queued drops).
    private var optimisticMoves: [OptimisticMove] = []

    private struct OptimisticMove {
        var id: CGWindowID
        var section: MenuBarSection
        var index: Int
    }

    @ObservationIgnored private var isWindowVisible = false
    @ObservationIgnored private var isTabSelected = false
    @ObservationIgnored private(set) var isActive = false
    /// This activation has entered editing and the menu bar has settled (a full refresh before that would read a menu
    /// bar that is still rearranging).
    private var hasSettled = false
    /// Incremented on each activation; async completions compare it with their captured value to discard results
    /// from an earlier session.
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Waits for Accessibility while the tab is visible without it.
    @ObservationIgnored private var permissionTask: Task<Void, Never>?
    @ObservationIgnored private var endEditingTask: Task<Void, Never>?
    @ObservationIgnored private var errorTask: Task<Void, Never>?
    /// The move task of the most recent drop. Rapid successive drops queue behind it (in drop order) instead of
    /// asking the user to wait.
    @ObservationIgnored private var lastDrop: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
    }

    // MARK: - Visibility

    /// The Settings window became visible / invisible: opened, closed, minimized, restored from the Dock, Frost hidden
    /// or unhidden, the window covered or uncovered, the user away or back (called by
    /// `SettingsWindowController`; SwiftUI doesn't reliably send onDisappear when the window closes). The menu bar
    /// shouldn't stay in editing state while the window is minimized.
    func setWindowVisible(_ visible: Bool) {
        isWindowVisible = visible
        updateActivation()
    }

    /// The Layout tab appeared / disappeared (tab switch).
    func setTabSelected(_ selected: Bool) {
        isTabSelected = selected
        updateActivation()
    }

    private func updateActivation() {
        let shouldBeActive = isWindowVisible && isTabSelected
        guard shouldBeActive != isActive else { return }
        if shouldBeActive { activate() } else { deactivate() }
    }

    /// The Settings window became key (user switched back from another app): apps may have launched / quit or icons
    /// changed meanwhile, so do one full refresh.
    func windowDidBecomeKey() {
        guard isActive, hasSettled else { return }
        Task { await fullRefresh() }
    }

    private func activate() {
        isActive = true
        hasSettled = false
        session += 1
        let permissions = model.permissions
        permissions.refresh()
        permissions.startPolling()
        // Without Accessibility there is nothing to edit (the tab only explains how to grant it): leave the menu bar
        // alone, and start once the permission arrives while the tab is still visible.
        guard permissions.canManageItems else {
            permissionTask?.cancel()
            permissionTask = Task { [weak self] in
                while let self, self.isActive, !self.model.permissions.canManageItems {
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                }
                guard let self, self.isActive, !Task.isCancelled else { return }
                self.beginSession()
            }
            return
        }
        beginSession()
    }

    /// Enters editing and starts the refresh loop (the permission to manage items is there).
    private func beginSession() {
        let permissions = model.permissions
        // Show every item's disk-cached capture (the launch warm-up has usually loaded them already; anything else is
        // read off the main thread); items pushed off screen can't be captured until the menu bar has expanded.
        if permissions.screenRecording {
            let capturer = model.capturer, items = model.scanner.items
            Task {
                await capturer.preloadCached(items)
                // Items already on screen (the Visible section) can be captured right away, so a tile never shows its
                // app-icon placeholder and then swaps to the real image a moment later.
                let missing = capturer.missing(items.filter(\.isOnScreen))
                if !missing.isEmpty { await capturer.capture(missing) }
            }
        }

        endEditingTask?.cancel()
        endEditingTask = nil
        // The Frost Bar's click forwarding (move out -> click -> move back) is a move transaction whose move back must
        // happen collapsed: entering editing now would make it run in editing state (positions possibly under the
        // notch, unreliable). As `deactivate` waits for transactions before collapsing, wait for it to end first.
        let deferEditing = !model.sections.isEditing && model.mover.isBusy
        if !model.sections.isEditing, !deferEditing { enterEditing() }
        isWaitingForMover = deferEditing

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if deferEditing {
                while self?.model.mover.isBusy == true {
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                }
                guard let self, self.isActive, !Task.isCancelled else { return }
                // No suspension point between this and the isBusy check: no new transaction can start in between.
                if !self.model.sections.isEditing { self.enterEditing() }
                self.isWaitingForMover = false
            }
            // After beginEditing the separators narrow and items rearrange; wait for frames to settle before a full refresh.
            await self?.model.sections.waitForSettle()
            guard let self, self.isActive, !Task.isCancelled else { return }
            self.hasSettled = true
            await self.fullRefresh()
            var tick = 0
            while !Task.isCancelled, self.isActive {
                // Menu bar unreadable / separators missing: retry with a full refresh every 3 s; otherwise a cheap
                // refresh every 2 s.
                let isRetrying = self.phase.isFailure
                do { try await Task.sleep(for: .seconds(isRetrying ? 3 : 2)) } catch { return }
                guard self.isActive else { return }
                if self.phase.isFailure {
                    tick = 0
                    await self.fullRefresh()
                    continue
                }
                tick += 1
                if tick % 5 != 0 {
                    await self.refresh(recaptureVisible: false)
                } else if self.needsFullRefresh {
                    await self.fullRefresh()
                } else {
                    await self.refresh(recaptureVisible: true)
                }
            }
        }
    }

    /// The order is reliable while collapsed (or expanded normally): take the snapshot first, then enter editing.
    private func enterEditing() {
        model.scanner.rescan()
        previous = model.layout
        model.sections.beginEditing()
    }

    private func deactivate() {
        isActive = false
        hasSettled = false
        isWaitingForMover = false
        refreshTask?.cancel()
        refreshTask = nil
        permissionTask?.cancel()
        permissionTask = nil
        model.permissions.stopPolling()
        model.capturer.flushDiskCache()
        pending.removeAll()
        optimisticMoves.removeAll()
        errorTask?.cancel()
        errorMessage = nil

        guard model.sections.isEditing else { return }
        let mover = model.mover
        endEditingTask?.cancel()
        endEditingTask = Task { [weak self] in
            // Ending editing during a move collapses the menu bar and shifts the destination: collapse after the
            // transaction ends.
            while mover.isBusy {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            guard let self, !self.isActive, !Task.isCancelled else { return }
            self.model.sections.endEditing()
            self.endEditingTask = nil
        }
    }

    // MARK: - Derived state

    var phase: Phase {
        // Accessibility is enough; without Screen Recording tiles show app icons (`ItemFallbackAppearance`).
        if !model.permissions.canManageItems { return .needsPermission }
        if isWaitingForMover { return .loading }
        switch model.scanner.status {
        case .notScanned: return .loading
        case .noWindows: return .noWindows
        case .ok: return model.layout.isEmpty ? .controlsMissing : .ready
        }
    }

    /// The layout the editor shows: the live layout merged with `previous` (off-screen items keep their sections),
    /// with in-flight drops applied on top.
    var layout: MenuBarLayout {
        // Until the menu bar has settled after entering editing, live positions are transient: while the separators
        // shrink, the system briefly places items on the other side of a separator (on a notched Mac the first
        // hidden item was classified Always Hidden for ~0.4 s and visibly slid there and back). Show the snapshot
        // taken before editing until then.
        var layout = hasSettled || previous.isEmpty
            ? LayoutReconciler.reconcile(live: model.layout, previous: previous,
                                         separatorsOnScreen: separatorsOnScreen)
            : previous
        guard !layout.isEmpty else { return layout }
        for move in optimisticMoves {
            layout = LayoutReconciler.moving(move.id, to: move.section, at: move.index, in: layout)
        }
        return layout
    }

    /// Whether both of Frost's separators are on screen. While editing on a crowded notched display one of them can
    /// be squeezed under the notch; live sections are then classified against a separator that isn't where it really
    /// is, so the editor keeps the collapsed snapshot's sections (see `LayoutReconciler`).
    private var separatorsOnScreen: Bool {
        guard let controls = model.sections.controlWindows else { return true }
        let items = model.scanner.items
        return [controls.hiddenSeparator, controls.alwaysHiddenSeparator].allSatisfy { id in
            items.first { $0.windowID == id }?.isOnScreen ?? true
        }
    }

    var state: LayoutEditorState {
        let layout = layout
        let items = layout.values.flatMap { $0 }
        var names: [CGWindowID: String] = [:]
        var labels: [CGWindowID: String] = [:]
        var icons: [CGWindowID: NSImage] = [:]
        for item in items {
            names[item.windowID] = item.displayName
            labels[item.windowID] = item.accessibilityName
            if model.capturer.images[item.windowID] == nil, let icon = AppIconCache.shared.icon(for: item.bundleID) {
                icons[item.windowID] = icon
            }
        }
        let uncaptured = items.filter { model.capturer.images[$0.windowID] == nil }
        let fallbackLabels = ItemFallbackAppearance.labels(for: uncaptured)
        let displayBounds = model.scanner.menuBarDisplay?.frame ?? CGDisplayBounds(CGMainDisplayID())
        let obscured = hasSettled
            ? Set(items.filter { ItemMover.isObscured($0, displayBounds: displayBounds) }.map(\.windowID))
            : []
        return LayoutEditorState(
            phase: phase, layout: layout, images: model.capturer.images, imageSizes: model.capturer.sizes,
            tones: model.capturer.tones, names: names, accessibilityLabels: labels, fallbackLabels: fallbackLabels,
            appIcons: icons, pending: pending,
            obscured: obscured, errorMessage: errorMessage,
            isRetrying: isActive && fullRefreshSession == session,
            permissions: .init(accessibility: model.permissions.accessibility,
                               screenRecording: model.permissions.screenRecording,
                               screenRecordingNeedsRelaunch: model.permissions.screenRecordingNeedsRelaunch),
            showsScreenRecordingHint: model.preferences.showsScreenRecordingHint(model.permissions.capabilities))
    }

    // MARK: - Refreshing

    /// Periodic refresh: cheap rescan, commit the displayed layout, capture missing images (all visible items when
    /// `recaptureVisible`).
    /// Skipped while a move is in progress (it refreshes when done) or a full refresh is running (it does the same work).
    private func refresh(recaptureVisible: Bool) async {
        guard isActive, pending.isEmpty, !model.mover.isBusy, fullRefreshSession != session else { return }
        model.scanner.rescan()
        commitLayout()
        await capture(all: recaptureVisible)
    }

    /// Full refresh: forces a full AX read (ownership may have changed; AX is read on a background thread) and
    /// recaptures all visible items.
    /// Never concurrent within a session; skipped while a move is in progress (it refreshes when done).
    private func fullRefresh() async {
        let session = session
        guard isActive, fullRefreshSession != session, pending.isEmpty, !model.mover.isBusy else { return }
        fullRefreshSession = session
        defer { if fullRefreshSession == session { fullRefreshSession = nil } }
        model.permissions.refresh()
        await model.scanner.refreshOwnership()
        // The editor closed, a new session started, or a drop began during the read: don't modify state (the drop
        // refreshes when done).
        guard self.session == session, isActive, pending.isEmpty else { return }
        commitLayout()
        // Owners just resolved (e.g. items pushed off screen since launch): show their disk-cached images first.
        if model.permissions.screenRecording { await model.capturer.preloadCached(model.scanner.items) }
        await capture(all: true)
    }

    /// Some displayed item has an unknown owner, or is on screen without an image (e.g. a just-launched app's icon):
    /// a cheap refresh can't fix that, a full refresh is needed.
    private var needsFullRefresh: Bool {
        let canCapture = model.permissions.screenRecording
        return layout.values.joined().contains { item in
            item.bundleID == nil || (canCapture && item.isOnScreen && model.capturer.images[item.windowID] == nil)
        }
    }

    private func commitLayout() {
        let reconciled = LayoutReconciler.reconcile(live: model.layout, previous: previous,
                                                    separatorsOnScreen: separatorsOnScreen)
        guard !reconciled.isEmpty, Self.ids(reconciled) != Self.ids(previous) else { return }
        previous = reconciled
    }

    private func capture(all: Bool) async {
        // Editing shows every section: items off screen don't fit (behind the notch). Recorded for the background
        // capture, which fills in their images once the editor is closed.
        if hasSettled, !model.mover.isBusy, model.sections.isEditing {
            model.noteExpandedScan(expected: Set(model.scanner.items.map(\.windowID)))
        }
        guard model.permissions.screenRecording else { return }
        let items = model.scanner.items.filter(\.isOnScreen)
        let targets = all ? items : model.capturer.missing(items)
        guard !targets.isEmpty else { return }
        await model.capturer.capture(targets)
    }

    private static func ids(_ layout: MenuBarLayout) -> [MenuBarSection: [CGWindowID]] {
        layout.mapValues { $0.map(\.windowID) }
    }

    // MARK: - Drag and drop

    /// Drops `windowID` into `section` at `index` (already converted by `InsertionIndex.compute` to the index after
    /// removing the dragged item).
    ///
    /// The destination is resolved at drop time against the layout shown then (including earlier unfinished drops), and
    /// the dragged item is shown optimistically at its destination right away. The move itself is queued: while a
    /// previous drop or another move transaction (e.g. a Frost Bar move-back retry) is running, it waits for that to
    /// finish instead of asking the user to wait.
    func drop(_ windowID: CGWindowID, into section: MenuBarSection, at index: Int) async {
        guard isActive, !isWaitingForMover, let controls = model.sections.controlWindows else { return }
        let layout = layout
        guard let item = layout.values.lazy.flatMap({ $0 }).first(where: { $0.windowID == windowID }),
              let destination = DropResolver.destination(dragging: item, to: section, index: index,
                                                         layout: layout, controls: controls)
        else { return }

        if model.mover.isBusy || !pending.isEmpty {
            FrostLog.layout.notice("drop of \(windowID) queued behind \(self.pending.count) unfinished drop(s)")
        }
        let session = session
        pending.insert(windowID)
        optimisticMoves.append(OptimisticMove(id: windowID, section: section, index: index))
        let previousDrop = lastDrop
        let task = Task { [weak self] in
            await previousDrop?.value
            await self?.performMove(item, to: destination, section: section, index: index, layout: layout,
                                    session: session)
        }
        lastDrop = task
        await task.value
    }

    /// Performs one (possibly queued) drop move. If the editor closed or a new session started, neither moves nor
    /// modifies state.
    private func performMove(_ item: MenuBarItem, to destination: MoveDestination, section: MenuBarSection,
                             index: Int, layout: MenuBarLayout, session: Int) async {
        let windowID = item.windowID
        let mover = model.mover
        // The drop arrives while AppKit is still ending the drag session: start the ⌘-drag only once it has.
        await Self.waitForDragSessionToEnd()
        // Another move transaction is running, or the user holds a mouse button (e.g. already dragging the next tile: a
        // ⌘-drag must never start then): wait (no suspension point between here and `transaction` below, so no new
        // transaction can slip in).
        while mover.isBusy || UserMouseButtons.isAnyHeld, self.session == session, isActive {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard self.session == session, isActive else { return }

        // If the dragged item or the target is under the notch (doesn't fit in editing state), positions are
        // unreliable: collapse the menu bar temporarily during the move.
        let live = model.scanner.items
        let involved = [windowID, destination.targetWindowID].compactMap { id in live.first { $0.windowID == id } }
        let needsCollapse = involved.contains { !$0.isOnScreen }
        let sections = model.sections
        var succeeded = false
        do {
            try await mover.transaction {
                if needsCollapse {
                    try await sections.whileCollapsedForMove { try await mover.move(windowID, to: destination) }
                } else {
                    try await mover.move(windowID, to: destination)
                }
            }
            succeeded = true
        } catch ItemMoveError.shuttingDown {
            // Frost is quitting: the queued drop is simply not performed.
        } catch {
            // Any other failure (cancellation included) puts the tile back where it was: always say so.
            FrostLog.layout.error("drop of \(windowID) failed: \(error, privacy: .public)")
            if self.session == session, isActive {
                showError(String(localized: "Couldn’t move “\(item.displayName)”. Try again.",
                                 comment: "Layout editor error toast when moving a menu bar icon fails; the argument is the icon's name"))
            }
        }
        // The editor closed (or reopened as a new session): don't modify state.
        guard self.session == session, isActive else { return }
        if succeeded {
            // Move confirmed: the item stays where the user dropped it (even if it's still under the notch and its
            // live position is unreliable). `index` was computed against the layout shown at drop time (`layout`,
            // including new items not in `previous`, the live order, and earlier queued drops), so apply it to that
            // layout rather than `previous`.
            previous = LayoutReconciler.moving(windowID, to: section, at: index, in: layout)
            // Keep it in this section when its app relaunches (`SectionKeeper`).
            model.newItems.recordDrop(item, in: section)
        }
        if let i = optimisticMoves.firstIndex(where: { $0.id == windowID }) { optimisticMoves.remove(at: i) }
        pending.remove(windowID)
        model.scanner.rescan()
        commitLayout()
        await capture(all: false)
        // The moved item's image position changed (it may have just left the notch area): capture it separately.
        if let moved = model.scanner.items.first(where: { $0.windowID == windowID && $0.isOnScreen }),
           model.permissions.screenRecording {
            await model.capturer.capture([moved])
        }
    }

    /// Waits until the drag session that delivered a drop has fully ended: the mouse button is up and AppKit's drag
    /// image window is gone, plus a short grace (at most `dragEndTimeout` in all). `performDrop` runs while the session
    /// is still ending; ⌘-drag events posted then keep the drag image hanging over the drop spot for up to a second.
    private static func waitForDragSessionToEnd() async {
        let clock = ContinuousClock()
        let deadline = clock.now + dragEndTimeout
        while clock.now < deadline, UserMouseButtons.isAnyHeld || isDragImageOnScreen() {
            try? await Task.sleep(for: .milliseconds(16))
        }
        try? await Task.sleep(for: dragEndGrace)
    }

    private static let dragEndTimeout: Duration = .milliseconds(1500)
    private static let dragEndGrace: Duration = .milliseconds(50)

    /// Whether one of Frost's windows is on screen at the dragging level or above (AppKit's drag image window).
    private static func isDragImageOnScreen() -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        let level = Int(CGWindowLevelForKey(.draggingWindow))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { window in
            (window[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid
                && (window[kCGWindowLayer as String] as? Int ?? 0) >= level
        }
    }

    private func showError(_ message: String) {
        errorMessage = message
        errorTask?.cancel()
        errorTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            self?.errorMessage = nil
        }
    }

    // MARK: - Permissions

    func grantAccessibility() {
        model.permissions.requestAccessibility()
    }

    func grantScreenRecording() {
        model.permissions.requestScreenRecording()
    }

    /// The pane the user flips the switch in; next to Relaunch, so denying the prompt isn't a dead end.
    func openScreenRecordingSettings() {
        model.permissions.openScreenRecordingSettings()
    }

    func dismissScreenRecordingHint() {
        model.preferences.screenRecordingHintDismissed = true
    }
}

/// All the data the editor view needs to draw (a value type: views don't depend on services directly, so they can be
/// rendered offscreen with fake data).
struct LayoutEditorState {
    struct Permissions: Equatable {
        var accessibility: Bool
        var screenRecording: Bool
        /// Screen Recording was requested and takes effect after a relaunch.
        var screenRecordingNeedsRelaunch = false
    }

    var phase: LayoutEditorModel.Phase
    var layout: MenuBarLayout
    var images: [CGWindowID: CGImage]
    /// Size of each capture in points (a cached capture may be narrower or wider than the item is now: it is drawn at
    /// its own size until a fresh capture replaces it).
    var imageSizes: [CGWindowID: CGSize] = [:]
    var tones: [CGWindowID: GlyphTone]
    var names: [CGWindowID: String]
    /// VoiceOver labels (`MenuBarItem.accessibilityName`).
    var accessibilityLabels: [CGWindowID: String] = [:]
    /// Short labels for tiles without a captured image (`ItemFallbackAppearance.labels`).
    var fallbackLabels: [CGWindowID: String] = [:]
    /// App icons for items without a captured image.
    var appIcons: [CGWindowID: NSImage]
    var pending: Set<CGWindowID>
    /// Items that still don't fit after the menu bar expanded for editing (e.g. behind the notch). Empty until the
    /// menu bar has settled, so items that are merely pushed out while it expands never flash the "doesn't fit" badge.
    var obscured: Set<CGWindowID>
    var errorMessage: String?
    /// An automatic retry (full refresh) is in progress: shows progress when the menu bar can't be read or the
    /// separators can't be found.
    var isRetrying: Bool
    var permissions: Permissions
    /// Accessibility is granted but Screen Recording isn't, and the user hasn't closed the hint.
    var showsScreenRecordingHint = false
}

/// Actions sent by the editor view.
struct LayoutEditorActions {
    var drop: @MainActor (_ windowID: CGWindowID, _ section: MenuBarSection, _ index: Int) -> Void
    var grantAccessibility: @MainActor () -> Void
    var grantScreenRecording: @MainActor () -> Void
    /// Opens System Settings' Screen Recording pane (shown next to Relaunch while a relaunch is pending).
    var openScreenRecordingSettings: @MainActor () -> Void = {}
    var relaunch: @MainActor () -> Void
    var dismissScreenRecordingHint: @MainActor () -> Void = {}
}
