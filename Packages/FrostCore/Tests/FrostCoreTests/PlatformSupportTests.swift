import Foundation
import Testing
@testable import FrostCore

@Suite struct PlatformSupportTests {
    private func version(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }

    @Test func macOS26IsSupported() {
        #expect(PlatformSupport.isMenuBarSupported(osVersion: version(26)))
        #expect(PlatformSupport.isMenuBarSupported(osVersion: version(26, 6, 2)))
        #expect(PlatformSupport.isMenuBarSupported(osVersion: version(26, 99, 9)))
    }

    /// macOS 27 draws the whole menu bar in one system process: no per-item windows to see, push out or ⌘-drag.
    @Test func macOS27IsNotSupported() {
        #expect(!PlatformSupport.isMenuBarSupported(osVersion: version(27)))
        #expect(!PlatformSupport.isMenuBarSupported(osVersion: version(27, 1)))
    }

    /// A later major version may change the menu bar again: unsupported until measured.
    @Test func laterVersionsAreNotSupported() {
        #expect(!PlatformSupport.isMenuBarSupported(osVersion: version(28)))
        #expect(!PlatformSupport.isMenuBarSupported(osVersion: version(40)))
    }

    /// Frost's deployment target is 26; 16 is what macOS 26 reports to apps linked against an older SDK.
    @Test func earlierVersionsAreNotSupported() {
        #expect(!PlatformSupport.isMenuBarSupported(osVersion: version(15, 7)))
        #expect(!PlatformSupport.isMenuBarSupported(osVersion: version(16)))
    }

    /// The Debug-only test hook (`FROST_TEST_UNSUPPORTED_OS=1`) makes the supported version behave like 27.
    @Test func simulatingAnUnsupportedVersion() {
        #expect(!PlatformSupport.isMenuBarSupported(osVersion: version(26, 6, 2), simulateUnsupported: true))
        #expect(PlatformSupport.isMenuBarSupported(osVersion: version(26, 6, 2), simulateUnsupported: false))
        #expect(!PlatformSupport.isMenuBarSupported(osVersion: version(27), simulateUnsupported: false))
    }

    @Test func versionDescription() {
        #expect(PlatformSupport.describe(version(27)) == "27.0")
        #expect(PlatformSupport.describe(version(27, 1)) == "27.1")
        #expect(PlatformSupport.describe(version(26, 6, 2)) == "26.6.2")
    }
}
