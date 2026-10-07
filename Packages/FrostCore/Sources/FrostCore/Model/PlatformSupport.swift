import Foundation

/// Which macOS versions Frost can manage the menu bar on.
///
/// Everything Frost does relies on how macOS 26 builds the menu bar: one layer-25 window per status item (scanning,
/// captures), a wide separator that pushes the items on its left off screen (hiding), and ⌘-drags routed to an item's
/// window (moves). macOS 27 draws the whole menu bar in one system process: there are no per-item windows, a too-wide
/// separator is dropped from the bar instead of pushing anything out, and ⌘-drags can't be routed
/// (`docs/macos-behavior.md`, "macOS 27"). On any version that isn't known to work, Frost leaves the menu bar alone: it
/// shows only the snowflake, which says so, and keeps updates working so a release that supports it can arrive.
public enum PlatformSupport {
    /// The major macOS versions whose menu bar Frost has been measured on and supports.
    public static let supportedMajorVersions: ClosedRange<Int> = 26...26

    /// Whether Frost can manage the menu bar on `osVersion` (unknown later versions are not supported until measured).
    public static func isMenuBarSupported(osVersion: OperatingSystemVersion) -> Bool {
        supportedMajorVersions.contains(osVersion.majorVersion)
    }

    /// The same, with the Debug-only test hook `FROST_TEST_UNSUPPORTED_OS=1` (read by the app layer) making a supported
    /// version behave like an unsupported one, so the unsupported mode can be exercised in the macOS 26 VM.
    public static func isMenuBarSupported(osVersion: OperatingSystemVersion, simulateUnsupported: Bool) -> Bool {
        !simulateUnsupported && isMenuBarSupported(osVersion: osVersion)
    }

    /// "27.0", "26.6.2" (for the log; the patch version only when there is one).
    public static func describe(_ version: OperatingSystemVersion) -> String {
        var text = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion != 0 { text += ".\(version.patchVersion)" }
        return text
    }
}
