import AppKit
import FrostCore
import SwiftUI

/// What this launch of Frost can do with the menu bar, decided once (`PlatformSupport`), and the notice shown when
/// that is nothing at all.
enum RunningOS {
    /// Environment variable `FROST_TEST_UNSUPPORTED_OS=1` (Debug builds, VM testing only): behave as on an
    /// unsupported macOS version, so the notice-only mode can be exercised in the macOS 26 VM.
    #if DEBUG
    private static let simulated = ProcessInfo.processInfo.environment["FROST_TEST_UNSUPPORTED_OS"] == "1"
    #else
    private static let simulated = false
    #endif

    /// The backend for the running macOS (26: window list; 27: Accessibility; anything else: notice only).
    static let backend = PlatformSupport.backend(osVersion: ProcessInfo.processInfo.operatingSystemVersion,
                                                 simulateUnsupported: simulated)

    /// Whether Frost manages the menu bar in this process.
    static var isMenuBarSupported: Bool { backend.managesMenuBar }

    /// Whether Frost can capture icon images on this macOS. Only the window-based backend can: the macOS 27 backend
    /// has no per-item windows to capture, and its replacement (a capture of the menu bar strip) is not implemented
    /// yet. Everything that offers Screen Recording reads this, so Frost never asks for a permission it cannot use.
    static var usesScreenRecording: Bool { backend == .windowList }

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
                Text(RunningOS.title)
                    .font(.headline)
                Text(RunningOS.detail)
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
