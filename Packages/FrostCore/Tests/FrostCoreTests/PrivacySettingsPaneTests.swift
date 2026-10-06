import Testing
@testable import FrostCore

@Suite struct PrivacySettingsPaneTests {
    @Test func everyPaneOpensItsOwnPrivacyAnchor() {
        for pane in PrivacySettingsPane.allCases {
            let url = pane.url
            #expect(url?.scheme == "x-apple.systempreferences")
            #expect(url?.absoluteString == "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")
        }
    }

    /// The anchors are the ones System Settings uses for the two panes Frost links to.
    @Test func theAnchorsAreTheOnesSystemSettingsUses() {
        #expect(PrivacySettingsPane.accessibility.url?.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        #expect(PrivacySettingsPane.screenRecording.url?.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    @Test func theTwoPanesAreDistinct() {
        #expect(PrivacySettingsPane.allCases.count == 2)
        #expect(Set(PrivacySettingsPane.allCases.map(\.rawValue)).count == 2)
    }
}
