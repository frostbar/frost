import Foundation

/// How Frost manages the menu bar on the running macOS, decided once at launch.
///
/// The two supported generations of the menu bar need different mechanisms behind the same user interface:
///
/// - macOS 26 gives every status item its own layer-25 window. Scanning reads CGWindowList and resolves the owner
///   through Accessibility; hiding sets a separator to `length = 10_000` (the system clamps it to 5016 pt), which
///   pushes the items on its left off screen; a move is a ⌘-drag routed to the item's window through CGEvent field
///   `0x33`; icon images come from per-window ScreenCaptureKit captures.
/// - macOS 27 draws the whole bar in one system process (`MenuBarAgent`, `docs/macos-behavior.md`, "macOS 27"), so
///   there are no per-item windows: item identities and geometry come from the Accessibility extras
///   (`AXExtrasReader`), hiding uses a pair of *bounded* dividers (`BoundedDivider`), images come from a capture of
///   the menu bar strip, and a hidden item is clicked through its Accessibility element.
///
/// Everything a version can't do stays behind this decision; a version Frost has not been measured on gets
/// `.noticeOnly`: only the snowflake, which says so, with updates still working so a release that supports it can
/// arrive.
public enum MenuBarBackend: Equatable, Sendable {
    /// macOS 26: per-item status windows (`MenuBarItemScanner`, wide separators, ⌘-drags routed by `0x33`).
    case windowList
    /// macOS 27: Accessibility-only (`AXMenuBarInventory`, bounded dividers).
    case accessibility
    /// A macOS version whose menu bar Frost doesn't manage (older versions and unmeasured future ones).
    case noticeOnly

    /// Whether Frost manages the menu bar at all in this mode.
    public var managesMenuBar: Bool { self != .noticeOnly }
}

/// Which macOS versions Frost can manage the menu bar on.
public enum PlatformSupport {
    /// The major macOS versions whose menu bar Frost has been measured on and supports.
    public static let supportedMajorVersions: ClosedRange<Int> = 26...27

    /// The backend for `osVersion`. Versions Frost has no measurements for are `.noticeOnly`.
    public static func backend(osVersion: OperatingSystemVersion,
                               simulateUnsupported: Bool = false) -> MenuBarBackend {
        guard !simulateUnsupported else { return .noticeOnly }
        switch osVersion.majorVersion {
        case 26: return .windowList
        case 27: return .accessibility
        default: return .noticeOnly
        }
    }

    /// Whether Frost can manage the menu bar on `osVersion` (unknown later versions are not supported until measured).
    public static func isMenuBarSupported(osVersion: OperatingSystemVersion) -> Bool {
        backend(osVersion: osVersion).managesMenuBar
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
