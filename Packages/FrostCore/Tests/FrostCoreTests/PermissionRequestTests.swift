import Testing
@testable import FrostCore

@Suite struct PermissionRequestTests {
    @Test func aPromptThatShowsUpEndsTheRequest() {
        #expect(PermissionRequest.decide(elapsed: .milliseconds(300), promptVisible: true) == .promptShown)
        // Even right at the deadline: the prompt wins.
        #expect(PermissionRequest.decide(elapsed: PermissionRequest.promptTimeout, promptVisible: true) == .promptShown)
    }

    @Test func noPromptYetKeepsWaitingUntilTheTimeout() {
        #expect(PermissionRequest.decide(elapsed: .zero, promptVisible: false) == .keepWaiting)
        let almost = PermissionRequest.promptTimeout - .milliseconds(1)
        #expect(PermissionRequest.decide(elapsed: almost, promptVisible: false) == .keepWaiting)
    }

    /// The system API stayed silent (it prompts once per process and only while the permission has no entry): Frost is
    /// already listed in Privacy & Security, so open the pane.
    @Test func noPromptByTheTimeoutOpensTheSettingsPane() {
        #expect(PermissionRequest.decide(elapsed: PermissionRequest.promptTimeout, promptVisible: false) == .openSettings)
        #expect(PermissionRequest.decide(elapsed: .seconds(10), promptVisible: false) == .openSettings)
    }

    @Test func thePromptIsRecognizedByItsOwner() {
        #expect(PermissionRequest.isPromptWindow(ownerName: "universalAccessAuthWarn"))
        #expect(!PermissionRequest.isPromptWindow(ownerName: "System Settings"))
        #expect(!PermissionRequest.isPromptWindow(ownerName: nil))
    }
}
