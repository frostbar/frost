import Testing
import CoreGraphics
@testable import FrostCore

@Suite struct OwnershipRefreshPolicyTests {
    let now = ContinuousClock.now

    @Test func allCachedSkipsFullRead() {
        #expect(!OwnershipRefreshPolicy.needsFullRead(windowIDs: [1, 2, 3], cached: [1, 2, 3, 4],
                                                      unresolvedSince: [:], now: now))
    }

    @Test func emptyWindowListSkipsFullRead() {
        #expect(!OwnershipRefreshPolicy.needsFullRead(windowIDs: [], cached: [], unresolvedSince: [:], now: now))
    }

    @Test func unknownWindowForcesFullRead() {
        #expect(OwnershipRefreshPolicy.needsFullRead(windowIDs: [1, 2, 9], cached: [1, 2],
                                                     unresolvedSince: [:], now: now))
    }

    @Test func recentlyUnresolvedWindowIsNotRetried() {
        let since = now.advanced(by: .seconds(-4.9))
        #expect(!OwnershipRefreshPolicy.needsFullRead(windowIDs: [1, 7], cached: [1],
                                                      unresolvedSince: [7: since], now: now))
    }

    @Test func unresolvedWindowIsRetriedAfterInterval() {
        let since = now.advanced(by: .seconds(-5))
        #expect(OwnershipRefreshPolicy.needsFullRead(windowIDs: [1, 7], cached: [1],
                                                     unresolvedSince: [7: since], now: now))
    }

    /// Unresolved windows after a read: the scanner reads again by itself a few times (right after launch nothing else
    /// may rescan), then stops.
    @Test func schedulesABoundedNumberOfRetriesForUnresolvedWindows() {
        #expect(OwnershipRefreshPolicy.shouldScheduleRetry(unresolved: 4, retriesSoFar: 0))
        #expect(OwnershipRefreshPolicy.shouldScheduleRetry(unresolved: 1, retriesSoFar: 2))
        #expect(!OwnershipRefreshPolicy.shouldScheduleRetry(unresolved: 1, retriesSoFar: 3))
        #expect(!OwnershipRefreshPolicy.shouldScheduleRetry(unresolved: 0, retriesSoFar: 0))
    }
}
