import AppKit
import FrostCore

/// System glue for the "close on outside click" fallback (decisions live in `OutsideClickDismissal`): while waiting for
/// a non-menu presentation opened by a forwarded click to close, global + local mouse monitors watch for clicks. If the
/// user clicks outside the presentation and the item and the presentation still doesn't close, click the item again to
/// toggle it closed (sending Esc first when the target app is frontmost).
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
    private var monitors: [Any] = []
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
        NonMenuPresentationHooks(presented: { _ in await self.arm() },
                                 poll: { isFading in await self.poll(isFading: isFading) })
    }

    func stop() {
        stopped = true
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    private func arm() {
        guard !stopped, monitors.isEmpty else { return }
        ownerWasActive = owner?.isActive ?? false
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Clicks in other apps (including the presentation itself and the menu bar).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseDown(event) }
        }) {
            monitors.append(global)
        }
        // Clicks in Frost's own windows (settings, onboarding, the Frost icon).
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseDown(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func mouseDown(_ event: NSEvent) {
        guard !stopped else { return }
        // Global monitor events have no window, so `locationInWindow` is in screen coordinates (AppKit, bottom-left
        // origin).
        let screenPoint = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
        let point = OutsideClickDismissal.cgPoint(fromAppKit: screenPoint,
                                                  primaryScreenMaxY: NSScreen.screens.first?.frame.maxY ?? 0)
        let frames = ItemClicker.ownerWindowFrames(ownerPID: pid, baseline: baseline)
        dismissal.mouseDown(at: point, time: .now, presentationFrames: frames.presentation,
                            itemFrame: currentItem().frame, ownerWindowFrames: frames.other,
                            ownerIsActive: ownerWasActive || owner?.isActive == true)
    }

    /// Returns true to end the wait.
    private func poll(isFading: Bool) async -> Bool {
        guard !stopped else { return false }
        let ownerIsActive = owner?.isActive ?? false
        let action = dismissal.poll(now: .now, isFading: isFading, ownerIsActive: ownerIsActive)
        ownerWasActive = ownerIsActive
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
        guard let window = StatusWindowParser.currentWindows().first(where: { $0.windowID == item.windowID })
        else { return item }
        return MenuBarItem(windowID: item.windowID, frame: window.frame, isOnScreen: window.isOnScreen,
                           windowTitle: item.windowTitle, bundleID: item.bundleID, pid: item.pid,
                           axDescription: item.axDescription)
    }
}
