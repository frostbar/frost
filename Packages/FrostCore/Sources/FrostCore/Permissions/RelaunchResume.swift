import Foundation

/// A Frost window to reopen after a relaunch.
public enum ResumeWindow: Equatable, Sendable {
    case onboarding
    /// The settings window on the tab with this raw value (`SettingsTab` lives in the app layer).
    case settings(tab: String)

    private static let settingsPrefix = "settings:"

    /// How it is stored in user defaults.
    public var storedValue: String {
        switch self {
        case .onboarding: "onboarding"
        case .settings(let tab): Self.settingsPrefix + tab
        }
    }

    public init?(storedValue: String) {
        if storedValue == "onboarding" {
            self = .onboarding
        } else if storedValue.hasPrefix(Self.settingsPrefix), storedValue.count > Self.settingsPrefix.count {
            self = .settings(tab: String(storedValue.dropFirst(Self.settingsPrefix.count)))
        } else {
            return nil
        }
    }
}

/// Reopens the window the user was granting permissions in after Frost relaunches.
///
/// Screen Recording only takes effect after a relaunch: either Frost's own Relaunch button, or System Settings'
/// "Quit & Reopen", which quits Frost normally and opens it again. Both go through `applicationWillTerminate`, which
/// records the frontmost visible Frost window while a Screen Recording request is pending (`windowToRestore`); the next
/// launch consumes the record once. A record older than `maxAge` is ignored, so an ordinary quit followed by a later
/// launch never reopens a window.
public enum RelaunchResume {
    static let key = "resumeWindowAfterRelaunch"
    static let dateKey = "resumeWindowAfterRelaunchDate"
    /// Written by versions up to 0.3.0 before relaunching from onboarding (the relaunched process may be a newer
    /// version when an update is installed on quit).
    static let legacyOnboardingKey = "resumeOnboardingAfterRelaunch"

    /// A relaunch (or "Quit & Reopen") opens Frost again within seconds.
    public static let maxAge: TimeInterval = 60

    /// The window to reopen when Frost terminates now: the frontmost visible Frost window (onboarding or settings,
    /// front to back), but only while the user is waiting on a Screen Recording grant that needs a relaunch.
    public static func windowToRestore(screenRecordingPending: Bool,
                                       visibleFrontToBack: [ResumeWindow]) -> ResumeWindow? {
        guard screenRecordingPending else { return nil }
        return visibleFrontToBack.first
    }

    public static func record(_ window: ResumeWindow, in defaults: UserDefaults = .standard, at date: Date = .now) {
        defaults.set(window.storedValue, forKey: key)
        defaults.set(date.timeIntervalSinceReferenceDate, forKey: dateKey)
    }

    /// Reads and clears the record; nil when there is none or it is stale.
    public static func consume(from defaults: UserDefaults = .standard, now: Date = .now) -> ResumeWindow? {
        let legacy = defaults.bool(forKey: legacyOnboardingKey)
        let stored = defaults.string(forKey: key)
        let recorded = defaults.object(forKey: dateKey) as? Double
        defaults.removeObject(forKey: legacyOnboardingKey)
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: dateKey)
        if let stored, let recorded {
            let age = now.timeIntervalSinceReferenceDate - recorded
            if age >= 0, age <= maxAge, let window = ResumeWindow(storedValue: stored) { return window }
        }
        return legacy ? .onboarding : nil
    }
}
