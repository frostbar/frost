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
        static let keepItemSections = "keepItemSections"
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

    /// Move an icon back into the section the user keeps it in when its app relaunches and the system re-adds it
    /// elsewhere (`SectionKeeper`).
    var keepItemSections: Bool {
        didSet { defaults.set(keepItemSections, forKey: Key.keepItemSections) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoRehide = defaults.object(forKey: Key.autoRehide) as? Bool ?? true
        autoRehideDelay = defaults.object(forKey: Key.autoRehideDelay) as? Double ?? 15
        displayMode = defaults.string(forKey: Key.displayMode).flatMap(DisplayMode.init(rawValue:)) ?? .automatic
        hasCompletedOnboarding = defaults.object(forKey: Key.hasCompletedOnboarding) as? Bool ?? false
        keepItemSections = defaults.object(forKey: Key.keepItemSections) as? Bool ?? true
    }

    /// The display mode in effect: always in place without permissions (basic hide/show needs none, the Frost Bar
    /// does); `.automatic` uses the Frost Bar on displays with a notch (`safeAreaInsets.top > 0`), in place otherwise.
    func effectiveDisplayMode(for screen: NSScreen?, permissionsGranted: Bool) -> DisplayMode {
        guard permissionsGranted else { return .inline }
        switch displayMode {
        case .automatic: return Self.hasNotch(screen) ? .frostBar : .inline
        case .inline, .frostBar: return displayMode
        }
    }

    private static func hasNotch(_ screen: NSScreen?) -> Bool {
        guard let screen else { return false }
        if treatPrimaryDisplayAsNotched, screen == NSScreen.screens.first { return true }
        return screen.safeAreaInsets.top > 0
    }

    /// Environment variable `FROST_TEST_NOTCH_PRIMARY_DISPLAY=1` (VM testing only): Automatic treats the primary
    /// display as notched, so the VM (which has no notch) can mix the Frost Bar on one display with In Menu Bar on a
    /// second one.
    #if DEBUG
    private static let treatPrimaryDisplayAsNotched =
        ProcessInfo.processInfo.environment["FROST_TEST_NOTCH_PRIMARY_DISPLAY"] == "1"
    #else
    private static let treatPrimaryDisplayAsNotched = false
    #endif
}
