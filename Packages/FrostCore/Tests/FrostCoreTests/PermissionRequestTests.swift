import Testing
@testable import FrostCore

@Suite struct PermissionRequestTests {
    @Test func theFirstRequestOnlyShowsTheSystemPrompt() {
        #expect(PermissionRequest.step(alreadyAsked: false) == .systemPrompt)
    }

    @Test func laterRequestsOpenTheSettingsPaneWithoutAPrompt() {
        #expect(PermissionRequest.step(alreadyAsked: true) == .openSettings)
    }
}
