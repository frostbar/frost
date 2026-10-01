import AppKit
import FrostCore
import Observation

/// Tracks whether the user is at the Mac (`UserPresence`): display sleep, screen lock, fast user switching and system
/// sleep. Posts `didChangeNotification` when `isAway` flips; the Frost Bar closes (stopping its live refresh) and the
/// layout editor pauses while away.
@Observable
@MainActor
final class UserPresenceMonitor {
    static let didChangeNotification = Notification.Name("dev.frost.Frost.userPresenceDidChange")

    private(set) var presence = UserPresence()
    var isAway: Bool { presence.isAway }

    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// Distributed notifications posted by the login window when the screen is locked / unlocked.
    private static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    private static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    func start() {
        guard observers.isEmpty else { return }
        // Launched while locked or in a background session (rare): start from the session's current state.
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if session["CGSSessionScreenIsLocked"] as? Bool == true { presence.update(.screenLocked, true) }
            if session[kCGSessionOnConsoleKey as String] as? Bool == false { presence.update(.sessionInactive, true) }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification, .displaysAsleep, true)
        observe(workspace, NSWorkspace.screensDidWakeNotification, .displaysAsleep, false)
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionInactive, true)
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive, false)
        observe(workspace, NSWorkspace.willSleepNotification, .systemSleeping, true)
        observe(workspace, NSWorkspace.didWakeNotification, .systemSleeping, false)
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Self.screenLocked, .screenLocked, true)
        observe(distributed, Self.screenUnlocked, .screenLocked, false)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ reason: UserPresence.Reason,
                         _ active: Bool) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update(reason, active) }
        }
        observers.append((center, observer))
    }

    private func update(_ reason: UserPresence.Reason, _ active: Bool) {
        guard presence.update(reason, active) else { return }
        let reasons = presence.reasons.map(\.rawValue).sorted().joined(separator: ", ")
        FrostLog.app.notice("user \(self.isAway ? "away" : "back", privacy: .public) (\(reasons, privacy: .public))")
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
