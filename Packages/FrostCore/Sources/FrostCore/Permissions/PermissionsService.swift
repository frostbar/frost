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
    /// Screen Recording was requested but isn't in effect yet: Frost has to relaunch once it is turned on.
    public var screenRecordingNeedsRelaunch: Bool { screenRecordingRequested && !screenRecording }
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
        screenRecordingRequested = true
        _ = CGRequestScreenCaptureAccess()
        promptTask?.cancel()
        promptTask = Task { [weak self] in
            let start = ContinuousClock.now
            while !Task.isCancelled {
                let visible = Self.isPermissionPromptOnScreen()
                switch PermissionRequest.decide(elapsed: ContinuousClock.now - start, promptVisible: visible) {
                case .promptShown: return
                case .openSettings:
                    self?.openSettings(anchor: "Privacy_ScreenCapture")
                    return
                case .keepWaiting:
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }
        }
    }

    @ObservationIgnored private var promptTask: Task<Void, Never>?

    private static func isPermissionPromptOnScreen() -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { PermissionRequest.isPromptWindow(ownerName: $0[kCGWindowOwnerName as String] as? String) }
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

    private func openSettings(anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
