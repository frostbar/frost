import Testing
@testable import FrostCore

/// While the system's Screen Recording prompt is up, the UI must not offer a relaunch yet: the user hasn't decided.
@Suite struct PermissionPromptWatchTests {
    @Test func pendingUntilThePromptAppearsAndCloses() {
        var watch = PermissionPromptWatch()
        #expect(watch.isPending)
        #expect(watch.observe(elapsed: .milliseconds(100), promptVisible: false) == .keepWatching)
        #expect(watch.observe(elapsed: .milliseconds(300), promptVisible: true) == .keepWatching)
        #expect(watch.isPending)
        // The user is still reading it long after the timeout: still pending.
        #expect(watch.observe(elapsed: .seconds(30), promptVisible: true) == .keepWatching)
        #expect(watch.isPending)
        #expect(watch.observe(elapsed: .seconds(31), promptVisible: false) == .promptClosed)
        #expect(!watch.isPending)
    }

    @Test func noPromptByTheTimeoutOpensTheSettingsPane() {
        var watch = PermissionPromptWatch()
        #expect(watch.observe(elapsed: .seconds(1), promptVisible: false) == .keepWatching)
        #expect(watch.observe(elapsed: PermissionRequest.promptTimeout, promptVisible: false) == .openSettings)
        #expect(!watch.isPending)
    }

    @Test func aFinishedWatchStaysFinished() {
        var watch = PermissionPromptWatch()
        _ = watch.observe(elapsed: .milliseconds(100), promptVisible: true)
        _ = watch.observe(elapsed: .milliseconds(200), promptVisible: false)
        #expect(watch.observe(elapsed: .milliseconds(300), promptVisible: true) == .finished)
        #expect(!watch.isPending)
    }
}
