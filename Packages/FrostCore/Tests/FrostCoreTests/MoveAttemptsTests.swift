import Testing
@testable import FrostCore

/// A user's click cutting a ⌘-drag short isn't a failure of the move: it gets another attempt without using up the
/// retries (bounded), so a click at the wrong moment doesn't send a moved-back icon to its fallback (the section's edge).
@Suite struct MoveAttemptsTests {
    @Test func failedAttemptsUseUpTheLimit() {
        var attempts = MoveAttempts(limit: 3, interruptionLimit: 4)
        #expect(attempts.mayAttempt(isShuttingDown: false))
        attempts.record(.failed)
        attempts.record(.failed)
        #expect(attempts.mayAttempt(isShuttingDown: false))
        attempts.record(.failed)
        #expect(!attempts.mayAttempt(isShuttingDown: false))
    }

    @Test func interruptedAttemptsDontCountAgainstTheLimit() {
        var attempts = MoveAttempts(limit: 1, interruptionLimit: 4)
        attempts.record(.interrupted)
        attempts.record(.notPosted)
        #expect(attempts.mayAttempt(isShuttingDown: false))
        attempts.record(.failed)
        #expect(!attempts.mayAttempt(isShuttingDown: false))
    }

    @Test func interruptionsAreBounded() {
        var attempts = MoveAttempts(limit: 3, interruptionLimit: 2)
        attempts.record(.interrupted)
        attempts.record(.interrupted)
        #expect(attempts.mayAttempt(isShuttingDown: false))
        attempts.record(.interrupted)
        #expect(!attempts.mayAttempt(isShuttingDown: false))
    }

    @Test func whileShuttingDownEveryAttemptCounts() {
        var attempts = MoveAttempts(limit: 3, interruptionLimit: 4, shutdownLimit: 1)
        #expect(attempts.mayAttempt(isShuttingDown: true))
        attempts.record(.interrupted)
        #expect(!attempts.mayAttempt(isShuttingDown: true))
        // Before quitting began it would have tried again.
        #expect(attempts.mayAttempt(isShuttingDown: false))
    }

    @Test func alwaysAtLeastOneAttempt() {
        #expect(MoveAttempts(limit: 0, interruptionLimit: 0).mayAttempt(isShuttingDown: false))
        #expect(MoveAttempts(limit: 3, interruptionLimit: 0, shutdownLimit: 0).mayAttempt(isShuttingDown: true))
    }
}
