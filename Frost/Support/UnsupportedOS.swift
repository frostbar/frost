import AppKit
import FrostCore
import SwiftUI

/// Frost on a macOS version whose menu bar it can't manage (`PlatformSupport`): the decision for this process and the
/// notice shown in the snowflake's menu and in Settings.
enum UnsupportedOS {
    /// Environment variable `FROST_TEST_UNSUPPORTED_OS=1` (Debug builds, VM testing only): behave as on an unsupported
    /// macOS version, so the unsupported mode can be exercised in the macOS 26 VM.
    #if DEBUG
    private static let simulated = ProcessInfo.processInfo.environment["FROST_TEST_UNSUPPORTED_OS"] == "1"
    #else
    private static let simulated = false
    #endif

    /// Whether Frost manages the menu bar in this process (decided once at launch).
    static let isMenuBarSupported = PlatformSupport.isMenuBarSupported(
        osVersion: ProcessInfo.processInfo.operatingSystemVersion, simulateUnsupported: simulated)

    /// "26.6.2" (for the log).
    static var versionDescription: String {
        PlatformSupport.describe(ProcessInfo.processInfo.operatingSystemVersion)
    }

    /// The notice's headline (the snowflake's menu, Settings).
    static var title: String {
        String(localized: "This version of macOS isn’t supported yet",
               comment: "Notice shown on a macOS version Frost can't manage the menu bar on (snowflake menu, Settings)")
    }

    /// The notice's explanation, naming the running macOS version.
    static var detail: String {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return String(localized: "Frost can’t hide icons on macOS \(major). An update is on the way.",
                      comment: "Notice shown on a macOS version Frost can't manage the menu bar on; the number is the macOS major version")
    }
}

/// The unsupported-macOS notice as a settings form row: a warning symbol, the headline and the explanation.
struct UnsupportedOSNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SymbolBadge(symbol: "exclamationmark.triangle.fill", tint: .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(UnsupportedOS.title)
                    .font(.headline)
                Text(UnsupportedOS.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
