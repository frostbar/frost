import AppKit
import ApplicationServices

public enum ItemClickError: Error, Equatable, Sendable {
    /// The item is not on screen (pushed off or under the notch): its menu would open off screen and a popover
    /// would be clamped to the left edge. Move it on screen before clicking.
    case notOnScreen
    /// AXPress returned an error that can neither be treated as delivered nor safely fall back to a CGEvent
    /// click (e.g. `.apiDisabled`).
    case pressFailed(AXError)
}

/// Result of `waitForPresentationToClose`.
public enum PresentationOutcome: Equatable, Sendable {
    /// No menu / popover was detected within `openTimeout`.
    case notPresented
    /// A presentation was detected and then disappeared from the screen.
    case closed
    /// The presentation is not a menu (popover / panel) and did not close within `nonMenuCap`. Menus have no
    /// cap, so they never produce this result.
    case timedOut
    /// The presentation is not a menu and `NonMenuPresentationHooks.poll` asked to stop waiting (the
    /// click-outside fallback has done its best to close it; see `OutsideClickDismissal`).
    case abandoned
}

/// Callbacks invoked while waiting for a **non-menu** presentation (popover / the app's own panel) to close,
/// used by the click-outside-to-dismiss fallback (see `OutsideClickDismissal`).
/// Never called for menus (a menu always closes on an outside click). The callbacks are awaited on the global
/// executor; callers hop back to the main actor themselves.
public struct NonMenuPresentationHooks: Sendable {
    /// Called once when a non-menu presentation is detected (the argument is its windows): install mouse
    /// monitors, etc.
    public var presented: @Sendable (_ windows: Set<CGWindowID>) async -> Void
    /// Called on every subsequent poll while the presentation is still on screen; `isFading` means its windows
    /// are fading out (alpha < 1). Return true to stop waiting (`.abandoned`).
    public var poll: @Sendable (_ isFading: Bool) async -> Bool

    public init(presented: @escaping @Sendable (_ windows: Set<CGWindowID>) async -> Void,
                poll: @escaping @Sendable (_ isFading: Bool) async -> Bool) {
        self.presented = presented
        self.poll = poll
    }
}

/// Frames (CG global coordinates) of the clicked app's current on-screen windows, used for the click-outside
/// check (`ItemClicker.ownerWindowFrames`).
public struct OwnerWindowFrames: Equatable, Sendable {
    /// Presentation windows (same detection rule as `waitForPresentationToClose`: menus outside the baseline
    /// plus the app's own windows with layer < 500).
    public var presentation: [CGRect]
    /// The app's other on-screen windows (e.g. a main window that was already open before the click).
    public var other: [CGRect]

    public init(presentation: [CGRect], other: [CGRect]) {
        self.presentation = presentation
        self.other = other
    }
}

/// Clicks menu bar items and detects when their menu / popover closes (implemented per spike-findings.md,
/// "Task 11").
public enum ItemClicker {
    /// Clicks an **on-screen** item. Prefers AXPress (background thread, 0.25 s messaging timeout); both
    /// `.success` and `.cannotComplete` count as delivered (once NSMenu enters its tracking loop the AX reply
    /// gets stuck, but the menu is already open; posting an extra CGEvent click then would close the menu).
    /// Falls back to a CGEvent click only when AX is explicitly unsupported or the AX element can't be found.
    ///
    /// Items in Frost's own process always use CGEvent: AXPress against our own process short-circuits on the
    /// calling thread (returns failure, or crashes when running a `@MainActor` action on a background thread).
    /// Apple system items (`com.apple.*`, see `acceptsAXPress`) also go straight to CGEvent.
    ///
    /// `forceEvent: true` skips AXPress and posts a CGEvent click directly: used to close a menu that is
    /// already open (AX messages are stuck during menu tracking so AXPress has no effect; a mouse click ends
    /// tracking).
    @concurrent
    public static func click(_ item: MenuBarItem, forceEvent: Bool = false) async throws {
        guard item.isOnScreen else { throw ItemClickError.notOnScreen }
        if !forceEvent, acceptsAXPress(bundleID: item.bundleID), let pid = item.pid, pid != getpid() {
            let frame = item.frame
            let error: AXError? = await Task.detached {
                guard let element = AXExtrasReader.element(pid: pid, matching: frame) else { return nil }
                AXUIElementSetMessagingTimeout(element, 0.25)
                return AXUIElementPerformAction(element, kAXPressAction as CFString)
            }.value
            if let error {
                switch pressDisposition(error) {
                case .delivered: return
                case .fallBackToEvent: break
                case .failed: throw ItemClickError.pressFailed(error)
                }
            }
        }
        let point = CGPoint(x: item.frame.midX, y: item.frame.midY)
        let windowID = item.windowID
        await Task.detached { postClick(at: point, windowID: windowID) }.value
    }

    /// Call before clicking to record the IDs of all current on-screen windows as the baseline.
    public static func onscreenWindowIDs() -> Set<CGWindowID> {
        Set(currentOnscreenWindows().map(\.windowID))
    }

    /// Presentation windows currently on screen that are outside the baseline and owned by `ownerPID` (menus
    /// at 101, popovers at 25, etc.; layer < 500, status item windows excluded).
    /// Used to spot menus opened by accident during a move: the mouse-down of a ⌘-drag occasionally makes the
    /// target item open its menu (at its pre-move position).
    /// Unlike `waitForPresentationToClose`, ownership must match here (other apps' menus don't count), to avoid
    /// a misdetection followed by an extra click.
    ///
    /// The baseline usually holds only on-screen windows (`onscreenWindowIDs()`), so the moved item's own status
    /// window, off screen before the move, is not in it. On macOS 26 all status windows belong to Control Center,
    /// so unless every status window is excluded, Control Center's own items (whose AX pid is also Control
    /// Center) would always mistake their own window for an "accidentally opened menu".
    public static func newWindows(ownedBy ownerPID: pid_t, excluding baseline: Set<CGWindowID>) -> Set<CGWindowID> {
        newWindows(in: currentOnscreenWindows(), ownedBy: ownerPID, excluding: baseline,
                   statusWindows: currentStatusWindowIDs())
    }

    /// Whether any menu is open on screen (layer 101, any app, including Frost's own). Auto-collapse is deferred
    /// while a menu is open.
    public static func isMenuOnScreen() -> Bool {
        containsMenu(currentOnscreenWindows())
    }

    /// Whether a menu other than `presentation`'s windows is on screen (e.g. one the user just opened elsewhere).
    public static func isForeignMenuOnScreen(excluding presentation: Set<CGWindowID>) -> Bool {
        containsForeignMenu(currentOnscreenWindows(), presentation: presentation)
    }

    /// All status item windows (layer-25 windows on the menu bar row, including off-screen ones and copies on
    /// other displays).
    public static func currentStatusWindowIDs() -> Set<CGWindowID> {
        statusWindowIDs(in: StatusWindowParser.currentWindows(), displays: activeDisplayBounds())
    }

    /// Waits for the menu / popover opened by the clicked item to appear and then disappear.
    /// - No new presentation detected within `openTimeout` → `.notPresented` (design doc: if no menu is
    ///   detected, move back immediately).
    /// - Once it appears, wait until it disappears → `.closed`. Limits per `closeWaitLimit`: menus (layer 101)
    ///   have no cap — a menu always closes when the user clicks elsewhere, and we never force the item back
    ///   while the user is still using the menu; popovers / panels don't necessarily close on an outside click,
    ///   so they wait at most `nonMenuCap` → `.timedOut`.
    /// - Non-menu presentations: `nonMenuHooks` is called on detection and on every subsequent poll (the
    ///   click-outside fallback) and may end the wait early → `.abandoned`.
    /// - Cancellable: throws `CancellationError` on cancellation; the caller moves the icon back on the same
    ///   defer/catch path (this is how the wait ends when Frost quits).
    /// Polls on the global executor without occupying the main thread (so it also runs during Frost's own menu
    /// tracking).
    @concurrent
    @discardableResult
    public static func waitForPresentationToClose(baseline: Set<CGWindowID>, ownerPID: pid_t?,
                                                  openTimeout: Duration = .seconds(1),
                                                  nonMenuCap: Duration = .seconds(60),
                                                  nonMenuHooks: NonMenuPresentationHooks? = nil) async throws -> PresentationOutcome {
        // Close poll at 100 ms: the click-outside fallback's grace period is evaluated on each poll, so a longer
        // interval delays the switch click (up to 150 ms late at 150 ms). Each poll reads CGWindowList once, so
        // the cost is negligible.
        try await waitForPresentationToClose(baseline: baseline, ownerPID: ownerPID, openTimeout: openTimeout,
                                             nonMenuCap: nonMenuCap, openPoll: .milliseconds(100),
                                             closePoll: .milliseconds(100), windows: currentOnscreenWindows,
                                             statusWindows: currentStatusWindowIDs, nonMenuHooks: nonMenuHooks)
    }

    /// Frames of the clicked app's (`ownerPID`) current presentation windows and other windows, for the
    /// click-outside check. Called on the main thread on mouse-down (reads CGWindowList once).
    public static func ownerWindowFrames(ownerPID: pid_t, baseline: Set<CGWindowID>) -> OwnerWindowFrames {
        ownerWindowFrames(in: currentOnscreenWindows(), ownerPID: ownerPID, baseline: baseline,
                          statusWindows: currentStatusWindowIDs())
    }

    /// Posts Esc (key down + key up, no modifiers) to `pid`: transient / semitransient popovers and most panels
    /// close on Esc. Delivered only to that process (`CGEvent.postToPid`), so the frontmost app is unaffected.
    public static func postEscape(toPID pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        let events = [true, false].compactMap { CGEvent(keyboardEventSource: source, virtualKey: escapeKeyCode, keyDown: $0) }
        // Post only if both were created, so we never send a lone key-down.
        guard events.count == 2 else { return }
        for event in events {
            event.flags = []
            event.postToPid(pid)
        }
    }

    /// kVK_Escape
    static let escapeKeyCode: CGKeyCode = 53

    // MARK: - Pure logic (unit tested)

    enum PressDisposition: Equatable {
        /// Delivered (the menu may already be open); don't post another click.
        case delivered
        /// Explicitly unsupported; fall back to a CGEvent click.
        case fallBackToEvent
        /// Any other error: don't fall back (the outcome is uncertain, and an extra click could close a menu that
        /// is already open).
        case failed
    }

    /// Apple system items (bundle ID starting with this prefix) are always clicked with a HID CGEvent, never
    /// AXPress. Measured in a VM on macOS 26.6: Spotlight's magnifying glass returns `.success` for AXPress but
    /// does nothing (a real click opens Spotlight), and `.success` counts as delivered so no click follows. Other
    /// system items (Text Input, Focus, etc.) may behave the same and can't all be verified, while HID clicks
    /// work for every system item — so we avoid AXPress by prefix rather than maintain a list.
    static let systemBundleIDPrefix = "com.apple."

    static func acceptsAXPress(bundleID: String?) -> Bool {
        guard let bundleID else { return true }
        return !bundleID.hasPrefix(systemBundleIDPrefix)
    }

    static func pressDisposition(_ error: AXError) -> PressDisposition {
        switch error {
        case .success, .cannotComplete: .delivered
        case .actionUnsupported, .attributeUnsupported, .noValue, .invalidUIElement, .failure: .fallBackToEvent
        default: .failed
        }
    }

    /// Condensed info about an on-screen window (parsed from a CGWindowList dictionary).
    struct WindowInfo: Hashable, Sendable {
        var windowID: CGWindowID
        var layer: Int
        var ownerPID: pid_t?
        /// CG global coordinates (top-left origin); `.zero` when there are no bounds.
        var frame: CGRect = .zero
        /// Window alpha (`kCGWindowAlpha`): < 1 during a fade-out animation.
        var alpha: Double = 1
    }

    static func windowInfos(from list: [[String: Any]]) -> [WindowInfo] {
        list.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? Int else { return nil }
            let frame = (info[kCGWindowBounds as String] as? [String: Any])
                .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            return WindowInfo(windowID: CGWindowID(number),
                              layer: info[kCGWindowLayer as String] as? Int ?? 0,
                              ownerPID: (info[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) },
                              frame: frame,
                              alpha: info[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }

    /// Presentation windows (as in `presentationWindowIDs`) and `ownerPID`'s other windows (excluding status
    /// windows and windows whose layer is outside `ownedPresentationLayers`).
    static func ownerWindowFrames(in windows: [WindowInfo], ownerPID: pid_t, baseline: Set<CGWindowID>,
                                  statusWindows: Set<CGWindowID>) -> OwnerWindowFrames {
        let presented = presentationWindowIDs(in: windows, baseline: baseline, statusWindows: statusWindows,
                                              ownerPID: ownerPID)
        var frames = OwnerWindowFrames(presentation: [], other: [])
        for window in windows {
            if presented.contains(window.windowID) {
                frames.presentation.append(window.frame)
            } else if window.ownerPID == ownerPID, !statusWindows.contains(window.windowID),
                      ownedPresentationLayers.contains(window.layer) {
                frames.other.append(window.frame)
            }
        }
        return frames
    }

    /// Whether any presentation window is fading out (alpha < 1): it is already closing.
    static func isFading(_ windows: [WindowInfo]) -> Bool {
        windows.contains { $0.alpha < 1 }
    }

    /// Window layer of NSMenu windows (measured in the spike).
    static let menuLayer = 101

    static func containsMenu(_ windows: [WindowInfo]) -> Bool {
        windows.contains { $0.layer == menuLayer }
    }

    /// Whether a menu (layer 101, any app) other than the presentation's own windows is on screen.
    static func containsForeignMenu(_ windows: [WindowInfo], presentation: Set<CGWindowID>) -> Bool {
        windows.contains { $0.layer == menuLayer && !presentation.contains($0.windowID) }
    }

    /// How long to wait for a detected presentation before giving up (nil = wait until it closes).
    /// - Contains a menu (layer 101): nil. A menu always closes when the user clicks elsewhere; a 60-second cap
    ///   would only close a menu the user is still using (the ⌘-drag of the move-back ends menu tracking).
    /// - Anything else (popovers, the app's own panels): `cap`. Some popovers don't close on an outside click
    ///   (not transient, or the app never truly activated); without a cap the icon would stay in the visible
    ///   section forever.
    static func closeWaitLimit(presented: [WindowInfo], cap: Duration) -> Duration? {
        containsMenu(presented) ? nil : cap
    }

    /// Layer bound for ownership-based presentation detection: after a ⌘-drag, Control Center leaves behind a
    /// layer-500 ghost window (37×39 in the spike) that must not count as the clicked item's presentation; menus
    /// (101), popovers (25) and the app's own panels are all below it.
    static let ownedPresentationLayers = 0..<500

    /// Presentation windows newly appearing outside the baseline: layer-101 menus, or windows owned by the
    /// clicked app with a layer within `ownedPresentationLayers` (including layer-25 popovers — on macOS 26 all
    /// status item windows belong to Control Center, so the app's own windows are its presentations).
    /// Status item windows (`statusWindows`) are always excluded: Control Center's own items are owned by
    /// Control Center, and their status windows (e.g. the clicked item itself, off screen before the move and
    /// hence not in the baseline) must not count as presentations.
    /// Measured noise (Notification Center 21, notifications 8, other apps 3, StatusIndicator 2147483630, drag
    /// ghost 500) is all excluded.
    static func presentationWindowIDs(in windows: [WindowInfo], baseline: Set<CGWindowID>,
                                      statusWindows: Set<CGWindowID>, ownerPID: pid_t?) -> Set<CGWindowID> {
        Set(windows.compactMap { window -> CGWindowID? in
            guard !baseline.contains(window.windowID), !statusWindows.contains(window.windowID) else { return nil }
            let isMenu = window.layer == menuLayer
            let isOwnedByItemApp = ownerPID.map { window.ownerPID == $0 } ?? false
            return isMenu || (isOwnedByItemApp && ownedPresentationLayers.contains(window.layer))
                ? window.windowID : nil
        })
    }

    static func newWindows(in windows: [WindowInfo], ownedBy ownerPID: pid_t, excluding baseline: Set<CGWindowID>,
                           statusWindows: Set<CGWindowID>) -> Set<CGWindowID> {
        Set(windows.lazy
            .filter { !baseline.contains($0.windowID) && !statusWindows.contains($0.windowID) }
            .filter { $0.ownerPID == ownerPID && ownedPresentationLayers.contains($0.layer) }
            .map(\.windowID))
    }

    /// Status item windows: layer 25 and on some display's menu bar row (top edge aligned with the display's top
    /// edge, height no taller than the menu bar). Popovers are also layer 25 but sit below the menu bar (spike:
    /// y = 31, height 106), so they don't count. Items pushed off screen have a negative x but are still on the
    /// row.
    static func statusWindowIDs(in windows: [RawStatusWindow], displays: [CGRect]) -> Set<CGWindowID> {
        Set(windows.lazy
            .filter { window in
                window.frame.height <= maxMenuBarHeight
                    && displays.contains { abs(window.frame.minY - $0.minY) < 1 }
            }
            .map(\.windowID))
    }

    /// Upper bound on menu bar height (39 pt on notched displays, 24–30 pt otherwise); taller layer-25 windows are
    /// not status items.
    static let maxMenuBarHeight: CGFloat = 60

    static func waitForPresentationToClose(baseline: Set<CGWindowID>, ownerPID: pid_t?,
                                           openTimeout: Duration, nonMenuCap: Duration,
                                           openPoll: Duration, closePoll: Duration,
                                           windows: () -> [WindowInfo],
                                           statusWindows: () -> Set<CGWindowID>,
                                           nonMenuHooks: NonMenuPresentationHooks? = nil) async throws -> PresentationOutcome {
        let clock = ContinuousClock()
        let openDeadline = clock.now + openTimeout
        var presented: Set<CGWindowID> = []
        var presentedWindows: [WindowInfo] = []
        while presented.isEmpty {
            if clock.now > openDeadline { return .notPresented }
            try await Task.sleep(for: openPoll)
            // Re-read status windows on every poll: status items that appear while waiting (e.g. an app adding
            // an icon) must be excluded too.
            let current = windows()
            presented = presentationWindowIDs(in: current, baseline: baseline, statusWindows: statusWindows(),
                                              ownerPID: ownerPID)
            presentedWindows = current.filter { presented.contains($0.windowID) }
        }
        // Menus have no cap: wait until closed (Task.sleep is a cancellation point; the caller cancels when
        // Frost quits).
        let closeDeadline = closeWaitLimit(presented: presentedWindows, cap: nonMenuCap).map { clock.now + $0 }
        // The click-outside fallback applies only to non-menu presentations.
        let hooks = containsMenu(presentedWindows) ? nil : nonMenuHooks
        await hooks?.presented(presented)
        while closeDeadline.map({ clock.now < $0 }) ?? true {
            try await Task.sleep(for: closePoll)
            let open = windows().filter { presented.contains($0.windowID) }
            if open.isEmpty { return .closed }
            if let hooks, await hooks.poll(isFading(open)) { return .abandoned }
        }
        return .timedOut
    }

    // MARK: - System glue

    static func currentOnscreenWindows() -> [WindowInfo] {
        windowInfos(from: CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
    }

    static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map(CGDisplayBounds)
    }

    /// A left click with no modifiers (clickState = 1, HID tap) at the center of the item's on-screen frame.
    /// Posted to the HID tap rather than the session tap: Spotlight's status item ignores synthetic clicks from
    /// the session tap (and AXPress) and only responds to HID-level events (measured in a VM on macOS 26.6;
    /// other apps' menus / popovers open either way).
    /// Also sets field `0x33 = windowID` (the same windowID routing ItemMover uses): measured that with
    /// position-only routing, the click is swallowed if the point is covered by a higher-level window (e.g. the
    /// lock screen's Shield window); with 0x33 it still reaches the target item.
    /// Called on a background thread; the cursor is restored afterwards.
    static func postClick(at point: CGPoint, windowID: CGWindowID) {
        SyntheticEventGate.posting { postClickNow(at: point, windowID: windowID) }
    }

    private static func postClickNow(at point: CGPoint, windowID: CGWindowID) {
        let source = CGEventSource(stateID: .hidSystemState)
        let savedCursor = CGEvent(source: nil)?.location
        defer { if let savedCursor { CGWarpMouseCursorPosition(savedCursor) } }
        // Send a lone mouse-up first: the windowID-routed mouse-down of a ⌘-drag move can leave the dragged item
        // in a "pressed" state, and the first synthetic click after that only ends the state without triggering
        // the action (known risk (a); measured in a VM: after a move, Spotlight swallows the first synthetic click
        // no matter how long we wait, but opens once a mouse-up is sent first). Items that aren't stuck ignore
        // this mouse-up.
        let events = [CGEventType.leftMouseUp, .leftMouseDown, .leftMouseUp].compactMap {
            CGEvent(mouseEventSource: source, mouseType: $0, mouseCursorPosition: point, mouseButton: .left)
        }
        // Post only if all were created, so we never send a lone mouse-down.
        guard events.count == 3 else { return }
        for e in events {
            e.flags = []
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            e.setIntegerValueField(ItemMover.windowIDField, value: Int64(windowID))
            e.post(tap: .cghidEventTap)
            usleep(30_000)
        }
    }
}
