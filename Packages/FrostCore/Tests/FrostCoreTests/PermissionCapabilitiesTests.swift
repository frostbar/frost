import Testing
@testable import FrostCore

@Suite struct PermissionCapabilitiesTests {
    let none = PermissionCapabilities(accessibility: false, screenRecording: false)
    let accessibilityOnly = PermissionCapabilities(accessibility: true, screenRecording: false)
    let screenRecordingOnly = PermissionCapabilities(accessibility: false, screenRecording: true)
    let all = PermissionCapabilities(accessibility: true, screenRecording: true)

    @Test func accessibilityAloneManagesItems() {
        #expect(accessibilityOnly.canManageItems)
        #expect(!accessibilityOnly.canCaptureImages)
        #expect(!accessibilityOnly.canLiveRefresh)
        #expect(accessibilityOnly.suggestsScreenRecording)
    }

    @Test func screenRecordingAloneOnlyCaptures() {
        #expect(!screenRecordingOnly.canManageItems)
        #expect(screenRecordingOnly.canCaptureImages)
        #expect(!screenRecordingOnly.canLiveRefresh)
        // The Frost Bar isn't available, so there are no tiles to improve yet.
        #expect(!screenRecordingOnly.suggestsScreenRecording)
    }

    @Test func everythingGranted() {
        #expect(all.canManageItems && all.canCaptureImages && all.canLiveRefresh)
        #expect(!all.suggestsScreenRecording)
    }

    @Test func nothingGranted() {
        #expect(!none.canManageItems && !none.canCaptureImages && !none.canLiveRefresh)
        #expect(!none.suggestsScreenRecording)
    }

    @Test func automaticUsesTheFrostBarOnNotchedDisplaysWithAccessibilityAlone() {
        #expect(DisplayMode.automatic.effective(hasNotch: true, capabilities: accessibilityOnly) == .frostBar)
        #expect(DisplayMode.automatic.effective(hasNotch: false, capabilities: accessibilityOnly) == .inline)
        #expect(DisplayMode.frostBar.effective(hasNotch: false, capabilities: accessibilityOnly) == .frostBar)
    }

    @Test func withoutAccessibilityHiddenIconsExpandInPlace() {
        for mode in DisplayMode.allCases {
            #expect(mode.effective(hasNotch: true, capabilities: none) == .inline)
            #expect(mode.effective(hasNotch: true, capabilities: screenRecordingOnly) == .inline)
        }
    }

    @Test func inlineStaysInline() {
        #expect(DisplayMode.inline.effective(hasNotch: true, capabilities: all) == .inline)
    }

    /// A macOS version where Frost has no captures (`MenuBarBackend`): a Screen Recording grant must not turn the
    /// capture and live-refresh paths on, and the UI must not suggest granting it either. This is the rule that was
    /// documented but not enforced until the capability itself carried it.
    @Test func aGrantDoesNotEnableCapturesWhereTheyAreNotSupported() {
        let granted = PermissionCapabilities(accessibility: true, screenRecording: true, capturesSupported: false)
        #expect(granted.canManageItems)
        #expect(!granted.canCaptureImages)
        #expect(!granted.canLiveRefresh)
        #expect(!granted.suggestsScreenRecording)
        // Everything else still works: hiding, showing and moving never needed Screen Recording.
        #expect(granted.canManageItems)
    }

    /// The same permissions where captures *are* supported behave as before.
    @Test func aGrantEnablesCapturesWhereTheyAreSupported() {
        let granted = PermissionCapabilities(accessibility: true, screenRecording: true, capturesSupported: true)
        #expect(granted.canCaptureImages)
        #expect(granted.canLiveRefresh)
        #expect(!granted.suggestsScreenRecording)

        let missing = PermissionCapabilities(accessibility: true, screenRecording: false, capturesSupported: true)
        #expect(!missing.canCaptureImages)
        #expect(missing.suggestsScreenRecording)
    }
}
