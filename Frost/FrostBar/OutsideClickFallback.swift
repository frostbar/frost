import AppKit
import FrostCore

/// System glue for the "close on outside click" fallback (decisions live in `OutsideClickDismissal`): while waiting for
/// a non-menu presentation opened by a forwarded click to close, global + local mouse monitors watch for clicks. If the
/// user clicks outside the presentation and the item and the presentation still doesn't close, click the item again to
/// toggle it closed (sending Esc first when the target app is frontmost). Esc and the toggle click wait while a mouse
/// button is held or another menu is open (`OutsideClickDismissal`), so they never cancel the user's drag-selection or
/// close a menu they just opened.
///
/// Lifecycle: `hooks.presented` installs the monitors and `stop()` removes them (callers use `defer` so every exit path
/// calls it).
@MainActor
final class OutsideClickFallback {
    private let item: MenuBarItem
    private let pid: pid_t
    private let baseline: Set<CGWindowID>
    private let owner: NSRunningApplication?
    private var dismissal = OutsideClickDismissal()
    private var monitors = EventMonitors()
    /// The presentation's windows (from `hooks.presented`); any other menu on screen defers Esc / the toggle click.
    private var presentation: Set<CGWindowID> = []
    private var loggedDeferral = false
    /// Whether the target app was frontmost at the last poll. By mouse-down it may already have lost activation to
    /// this click, so use the sample taken before it.
    private var ownerWasActive = false
    private var sentEscape = false
    private var stopped = false

    /// Returns nil when not applicable (unknown owner, Apple system item). `baseline` is the on-screen windows before
    /// the click.
    init?(item: MenuBarItem, baseline: Set<CGWindowID>) {
        guard OutsideClickDismissal.applies(ownerPID: item.pid, bundleID: item.bundleID), let pid = item.pid
        else { return nil }
        self.item = item
        self.pid = pid
        self.baseline = baseline
        owner = NSRunningApplication(processIdentifier: pid)
    }

    var hooks: NonMenuPresentationHooks {
        NonMenuPresentationHooks(presented: { windows in await self.arm(presentation: windows) },
                                 poll: { isFading in await self.poll(isFading: isFading) })
    }

    func stop() {
        stopped = true
        monitors.removeAll()
    }

    private func arm(presentation: Set<CGWindowID>) {
        guard !stopped, monitors.isEmpty else { return }
        self.presentation = presentation
        ownerWasActive = owner?.isActive ?? false
        // Clicks in other apps (including the presentation itself and the menu bar) and in Frost's own windows
        // (settings, onboarding, the Frost icon).
        monitors.add(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                     global: { [weak self] event in self?.mouseDown(event) })
    }

    private func mouseDown(_ event: NSEvent) {
        guard !stopped else { return }
        let point = ScreenCoordinates.cgPoint(fromAppKit: event.screenLocation)
        let frames = ItemClicker.ownerWindowFrames(ownerPID: pid, baseline: baseline)
        dismissal.mouseDown(at: point, time: .now, presentationFrames: frames.presentation,
                            itemFrame: currentItem().frame, ownerWindowFrames: frames.other,
                            ownerIsActive: ownerWasActive || owner?.isActive == true)
    }

    /// Returns true to end the wait.
    private func poll(isFading: Bool) async -> Bool {
        guard !stopped else { return false }
        let ownerIsActive = owner?.isActive ?? false
        let mousePressed = NSEvent.pressedMouseButtons != 0
        // Reading the window list is only worth it while an Esc / toggle click may be due.
        let mayAct = switch dismissal.phase {
        case .outsideClick, .escapeSent: true
        case .idle, .itemClicked, .finished: false
        }
        let foreignMenu = mayAct && ItemClicker.isForeignMenuOnScreen(excluding: presentation)
        let action = dismissal.poll(now: .now, isFading: isFading, ownerIsActive: ownerIsActive,
                                    isMouseButtonPressed: mousePressed, isForeignMenuOnScreen: foreignMenu)
        ownerWasActive = ownerIsActive
        if dismissal.isDeferring, !loggedDeferral {
            loggedDeferral = true
            FrostLog.activation.notice("""
                deferring the outside-click fallback for item \(self.item.windowID) \
                (mouse button held: \(mousePressed), another menu open: \(foreignMenu))
                """)
        }
        switch action {
        case .none:
            return false
        case .sendEscape:
            FrostLog.activation.notice(
                "presentation of item \(self.item.windowID) still open after an outside click; sending Esc to pid \(self.pid)")
            sentEscape = true
            ItemClicker.postEscape(toPID: pid)
            return false
        case .clickItem:
            if sentEscape {
                FrostLog.activation.notice(
                    "presentation of item \(self.item.windowID) ignored Esc; clicking the item to toggle it closed")
            } else {
                // Target app isn't frontmost: its popover isn't key and would ignore Esc, so toggle it closed.
                FrostLog.activation.notice("""
                    presentation of item \(self.item.windowID) still open after an outside click and its app is \
                    inactive; clicking the item to toggle it closed
                    """)
            }
            do {
                // Same HID click path as the forwarded click (not AXPress).
                try await ItemClicker.click(currentItem(), forceEvent: true)
            } catch {
                FrostLog.activation.error("toggle click failed: \(error, privacy: .public)")
            }
            return false
        case .giveUp:
            FrostLog.activation.notice("presentation of item \(self.item.windowID) did not close; restoring the icon anyway")
            return true
        }
    }

    /// The item's current frame (an app may change its icon width while the presentation is open); falls back to the
    /// frame at click time when it can't be read.
    private func currentItem() -> MenuBarItem {
        guard let window = StatusWindowParser.windows(withIDs: [item.windowID]).first
        else { return item }
        return item.with(frame: window.frame, isOnScreen: window.isOnScreen)
    }
}
