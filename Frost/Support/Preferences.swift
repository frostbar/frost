import AppKit
import Observation

/// User preferences. Read at init; every property writes back to `UserDefaults.standard` when it changes.
@Observable
@MainActor
final class Preferences {
    enum DisplayMode: String, CaseIterable, Sendable {
        /// Frost Bar on displays with a notch, in-place expansion elsewhere.
        case automatic
        /// Expand hidden items in place in the menu bar.
        case inline
        /// Show hidden items in the Frost Bar panel below the menu bar.
        case frostBar
    }

    private enum Key {
        static let autoRehide = "autoRehide"
        static let autoRehideDelay = "autoRehideDelay"
        static let displayMode = "displayMode"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var autoRehide: Bool {
        didSet { defaults.set(autoRehide, forKey: Key.autoRehide) }
    }

    /// Seconds.
    var autoRehideDelay: Double {
        didSet { defaults.set(autoRehideDelay, forKey: Key.autoRehideDelay) }
    }

    var displayMode: DisplayMode {
        didSet { defaults.set(displayMode.rawValue, forKey: Key.displayMode) }
    }

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoRehide = defaults.object(forKey: Key.autoRehide) as? Bool ?? true
        autoRehideDelay = defaults.object(forKey: Key.autoRehideDelay) as? Double ?? 15
        displayMode = defaults.string(forKey: Key.displayMode).flatMap(DisplayMode.init(rawValue:)) ?? .automatic
        hasCompletedOnboarding = defaults.object(forKey: Key.hasCompletedOnboarding) as? Bool ?? false
    }

    /// The display mode in effect: always in place without permissions (basic hide/show needs none, the Frost Bar
    /// does); `.automatic` uses the Frost Bar on displays with a notch (`safeAreaInsets.top > 0`), in place otherwise.
    func effectiveDisplayMode(for screen: NSScreen?, permissionsGranted: Bool) -> DisplayMode {
        guard permissionsGranted else { return .inline }
        switch displayMode {
        case .automatic: return (screen?.safeAreaInsets.top ?? 0) > 0 ? .frostBar : .inline
        case .inline, .frostBar: return displayMode
        }
    }
}
