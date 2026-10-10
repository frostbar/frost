import Foundation
import Testing
@testable import FrostCore

@Suite struct PlatformSupportTests {
    private func version(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }

    @Test func macOS26IsSupported() {
        #expect(PlatformSupport.backend(osVersion: version(26)) == .windowList)
        #expect(PlatformSupport.backend(osVersion: version(26, 6, 2)) == .windowList)
        #expect(PlatformSupport.backend(osVersion: version(26, 99, 9)) == .windowList)
        #expect(PlatformSupport.isMenuBarSupported(osVersion: version(26)))
    }

    /// macOS 27 draws the whole menu bar in one system process: item identities and geometry come from
    /// Accessibility, and hiding uses the bounded dividers instead of the wide separators of macOS 26.
    @Test func macOS27UsesTheAccessibilityBackend() {
        #expect(PlatformSupport.backend(osVersion: version(27)) == .accessibility)
        #expect(PlatformSupport.backend(osVersion: version(27, 1)) == .accessibility)
        #expect(PlatformSupport.isMenuBarSupported(osVersion: version(27)))
    }

    /// A later major version may change the menu bar again: unsupported until measured.
    @Test func laterVersionsAreNotSupported() {
        #expect(PlatformSupport.backend(osVersion: version(28)) == .noticeOnly)
        #expect(PlatformSupport.backend(osVersion: version(40)) == .noticeOnly)
        #expect(!PlatformSupport.isMenuBarSupported(osVersion: version(28)))
    }

    /// Frost's deployment target is 26; 16 is what macOS 26 reports to apps linked against an older SDK.
    @Test func earlierVersionsAreNotSupported() {
        #expect(PlatformSupport.backend(osVersion: version(15, 7)) == .noticeOnly)
        #expect(PlatformSupport.backend(osVersion: version(16)) == .noticeOnly)
    }

    /// The Debug-only test hook (`FROST_TEST_UNSUPPORTED_OS=1`) makes a supported version behave like 28.
    @Test func simulatingAnUnsupportedVersion() {
        #expect(PlatformSupport.backend(osVersion: version(26, 6, 2), simulateUnsupported: true) == .noticeOnly)
        #expect(PlatformSupport.backend(osVersion: version(27), simulateUnsupported: true) == .noticeOnly)
        #expect(!PlatformSupport.isMenuBarSupported(osVersion: version(27), simulateUnsupported: true))
        #expect(PlatformSupport.backend(osVersion: version(26, 6, 2), simulateUnsupported: false) == .windowList)
        #expect(PlatformSupport.backend(osVersion: version(27), simulateUnsupported: false) == .accessibility)
    }

    @Test func versionDescription() {
        #expect(PlatformSupport.describe(version(27)) == "27.0")
        #expect(PlatformSupport.describe(version(27, 1)) == "27.1")
        #expect(PlatformSupport.describe(version(26, 6, 2)) == "26.6.2")
    }
}
