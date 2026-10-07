import AppKit
import ApplicationServices
import Observation

@MainActor
@Observable
public final class PermissionsService {
    public private(set) var accessibility = false
    public private(set) var screenRecording = false
    /// The user asked for Screen Recording in this process (onboarding, About, the layout editor). A new grant only
    /// shows in `CGPreflightScreenCaptureAccess` after a relaunch, so the UI offers one meanwhile.
    public private(set) var screenRecordingRequested = false
    /// The system's Screen Recording prompt of the latest request is expected or on screen (`PermissionPromptWatch`):
    /// the user hasn't decided yet.
    public private(set) var isScreenRecordingPromptPending = false
    /// Screen Recording was requested but isn't in effect yet: Frost has to relaunch once it is turned on. Not while the
    /// system prompt is still up (the row would say "Needs Relaunch" under a prompt the user is still reading).
    public var screenRecordingNeedsRelaunch: Bool {
        screenRecordingRequested && !screenRecording && !isScreenRecordingPromptPending
    }
    /// What the current permissions allow (`PermissionCapabilities`): gate features on these, not on "all granted".
    public var capabilities: PermissionCapabilities {
        PermissionCapabilities(accessibility: accessibility, screenRecording: screenRecording)
    }
    /// The Frost Bar, the layout editor and moves (Accessibility).
    public var canManageItems: Bool { capabilities.canManageItems }
    /// Real images of icons (Screen Recording).
    public var canCaptureImages: Bool { capabilities.canCaptureImages }

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var accessibilityObserver: NSObjectProtocol?

    /// Reads once at startup, then refreshes every time the app is activated (e.g. the user switches back from
    /// System Settings). Operations that need permissions (opening Frost Bar, showing the layout editor, before a
    /// move) should also call `refresh()` first.
    public init() {
        refresh()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // System Settings posts this when the user flips an Accessibility switch: pick a grant up at once, also while
        // Frost isn't active (a click on the Frost icon right after granting must not see stale permissions).
        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            // The system updates its trust answer a moment after the notification.
            MainActor.assumeIsolated {
                self?.refresh()
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(300))
                    self?.refresh()
                }
            }
        }
    }

    /// Writes only when a value changes, so per-second polling doesn't trigger Observation updates.
    public func refresh() {
        let ax = AXIsProcessTrusted()
        let sr = CGPreflightScreenCaptureAccess()
        if accessibility != ax { accessibility = ax }
        if screenRecording != sr { screenRecording = sr }
    }

    /// Shows the system prompt (every call does); its "Open System Settings" button leads to the pane, with Frost
    /// listed. The pane is never opened here as well (`PermissionRequest`).
    public func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString  // kAXTrustedCheckOptionPrompt
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Asks through the system API; when no prompt shows up (it only prompts once per process), Frost is already
    /// listed and the pane is opened directly (`PermissionRequest`).
    public func requestScreenRecording() {
        // Pending first, so the UI never shows "Needs Relaunch" for a moment before the prompt appears.
        isScreenRecordingPromptPending = true
        screenRecordingRequested = true
        // The windows on screen right before the request: what appears afterwards is what the request caused
        // (`PermissionRequest.promptVisible`).
        let baseline = Self.windowSnapshots()
        _ = CGRequestScreenCaptureAccess()
        promptTask?.cancel()
        promptTask = Task { [weak self] in
            defer { if !Task.isCancelled { self?.isScreenRecordingPromptPending = false } }
            let start = ContinuousClock.now
            var watch = PermissionPromptWatch()
            // The prompt's windows once seen: it has closed when none of them is on screen any more.
            var prompt: Set<CGWindowID> = []
            while !Task.isCancelled {
                let current = Self.windowSnapshots()
                if prompt.isEmpty {
                    prompt = PermissionRequest.promptWindowIDs(baseline: baseline, current: current)
                }
                let visible = current.contains { $0.isOnScreen && prompt.contains($0.windowID) }
                switch watch.observe(elapsed: ContinuousClock.now - start, promptVisible: visible) {
                case .promptClosed, .finished:
                    return
                case .openSettings:
                    self?.open(PrivacySettingsPane.screenRecording)
                    return
                case .keepWatching:
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }
        }
    }

    /// Opens System Settings' Screen Recording pane (the row the user flips). Offered next to Relaunch while a
    /// relaunch is pending: a user who denied the prompt or closed it can get back to the pane in one click, without
    /// giving up the relaunch first (`screenRecordingNeedsRelaunch`).
    public func openScreenRecordingSettings() {
        open(PrivacySettingsPane.screenRecording)
    }

    @ObservationIgnored private var promptTask: Task<Void, Never>?

    /// The on-screen windows, with each owner's executable resolved (the window list doesn't carry it): the raw
    /// material of `PermissionRequest.promptVisible`.
    private static func windowSnapshots() -> [WindowSnapshot] {
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        var paths: [pid_t: String?] = [:]
        return infos.compactMap { info in
            guard let rawPID = info[kCGWindowOwnerPID as String] as? Int else { return nil }
            let pid = pid_t(rawPID)
            let path: String?
            if let known = paths[pid] {
                path = known
            } else {
                path = NSRunningApplication(processIdentifier: pid)?.executableURL?.path
                paths[pid] = path
            }
            return WindowSnapshot(windowInfo: info, ownerExecutablePath: path)
        }
    }

    @ObservationIgnored private var pollers = 0

    /// Reference-counted: onboarding, Frost Bar and the layout editor each start/stop while visible; polling only
    /// stops with the last stop.
    public func startPolling() {
        pollers += 1
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    public func stopPolling() {
        pollers = max(0, pollers - 1)
        guard pollers == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    private func open(_ pane: PrivacySettingsPane) {
        guard let url = pane.url else { return }
        NSWorkspace.shared.open(url)
    }
}
