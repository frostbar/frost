import Testing
import CoreGraphics
@testable import FrostCore

/// Quitting while moves are queued: once shutdown begins no new transaction may start (a queued editor drop or a
/// new-item placement could otherwise begin a ⌘-drag right before the app exits), except the move-back work that
/// quitting itself runs.
@MainActor @Suite struct ItemMoverShutdownTests {
    let mover = ItemMover(scanner: MenuBarItemScanner())

    @Test func transactionsRunNormallyBeforeShutdown() async throws {
        #expect(!mover.isShuttingDown)
        let value = try await mover.transaction { 42 }
        #expect(value == 42)
        #expect(!mover.isBusy)
    }

    @Test func newTransactionsThrowOnceShuttingDown() async {
        mover.beginShutdown()
        #expect(mover.isShuttingDown)
        var ran = false
        await #expect(throws: ItemMoveError.shuttingDown) {
            try await mover.transaction { ran = true }
        }
        #expect(!ran)
        #expect(!mover.isBusy)
    }

    @Test func moveBackWorkMayStillRunWhileShuttingDown() async throws {
        mover.beginShutdown()
        let value = try await mover.transaction(allowedDuringShutdown: true) { "restored" }
        #expect(value == "restored")
    }

    @Test func shutdownTakesPrecedenceOverBusy() async throws {
        try await mover.transaction {
            mover.beginShutdown()
            await #expect(throws: ItemMoveError.shuttingDown) {
                try await mover.transaction { }
            }
            await #expect(throws: ItemMoveError.busy) {
                try await mover.transaction(allowedDuringShutdown: true) { }
            }
        }
    }

    @Test func shutdownCapsTheAttemptsOfEachMove() {
        #expect(ItemMover.attemptLimit(requested: 3, isShuttingDown: false, shutdownLimit: 1) == 3)
        #expect(ItemMover.attemptLimit(requested: 3, isShuttingDown: true, shutdownLimit: 1) == 1)
        #expect(ItemMover.attemptLimit(requested: 1, isShuttingDown: true, shutdownLimit: 2) == 1)
        // Always at least one attempt.
        #expect(ItemMover.attemptLimit(requested: 0, isShuttingDown: false, shutdownLimit: 1) == 1)
        #expect(ItemMover.attemptLimit(requested: 3, isShuttingDown: true, shutdownLimit: 0) == 1)
    }

    @Test func waitUntilIdleReturnsAtOnceWhenIdle() async {
        #expect(await mover.waitUntilIdle(timeout: .zero))
    }

    @Test func waitUntilIdleWaitsForTheRunningTransaction() async throws {
        let running = Task { @MainActor in
            try await mover.transaction { try await Task.sleep(for: .milliseconds(60)) }
        }
        await Task.yield()
        #expect(mover.isBusy)
        #expect(await mover.waitUntilIdle(timeout: .seconds(5), poll: .milliseconds(5)))
        #expect(!mover.isBusy)
        try await running.value
    }

    @Test func waitUntilIdleGivesUpAfterTheTimeout() async throws {
        let running = Task { @MainActor in
            try await mover.transaction { try await Task.sleep(for: .milliseconds(300)) }
        }
        await Task.yield()
        #expect(!(await mover.waitUntilIdle(timeout: .milliseconds(20), poll: .milliseconds(5))))
        try await running.value
    }

    @Test func syntheticEventGateTracksPostsInFlight() {
        #expect(!SyntheticEventGate.isPosting)
        let inside = SyntheticEventGate.posting { SyntheticEventGate.isPosting }
        #expect(inside)
        #expect(!SyntheticEventGate.isPosting)
    }
}
