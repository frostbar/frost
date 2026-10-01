import Testing
@testable import FrostCore

@Suite struct DiskWriteThrottleTests {
    let t0 = ContinuousClock.now
    func s(_ seconds: Int) -> ContinuousClock.Instant { t0 + .seconds(seconds) }

    func offer(_ throttle: inout DiskWriteThrottle<String, Int>, _ value: Int, _ key: String, at time: Int) -> Int? {
        throttle.offer(value, for: key, now: s(time))
    }

    @Test func theFirstValueOfAKeyIsWrittenAtOnce() {
        var throttle = DiskWriteThrottle<String, Int>(interval: .seconds(60))
        #expect(offer(&throttle, 1, "clock", at: 0) == 1)
        // Another key is independent.
        #expect(offer(&throttle, 7, "cpu", at: 1) == 7)
        #expect(throttle.pending.isEmpty)
    }

    @Test func laterValuesWaitForTheIntervalKeepingOnlyTheNewest() {
        var throttle = DiskWriteThrottle<String, Int>(interval: .seconds(60))
        _ = offer(&throttle, 1, "clock", at: 0)
        // A dynamic icon changing every second: no writes within the interval.
        for t in 1..<60 { #expect(offer(&throttle, t + 1, "clock", at: t) == nil) }
        #expect(throttle.pending == ["clock": 60])
        // Once the interval has passed the next change is written (and replaces the pending one).
        #expect(offer(&throttle, 61, "clock", at: 60) == 61)
        #expect(throttle.pending.isEmpty)
    }

    @Test func pendingValuesBecomeDueAfterTheInterval() {
        // The icon changed once and then stopped: the held-back value is written once its key is due.
        var throttle = DiskWriteThrottle<String, Int>(interval: .seconds(60))
        _ = offer(&throttle, 1, "clock", at: 0)
        _ = offer(&throttle, 2, "clock", at: 5)
        let early = throttle.takeDue(now: s(30))
        #expect(early.isEmpty)
        let due = throttle.takeDue(now: s(60))
        #expect(due.map(\.key) == ["clock"])
        #expect(due.map(\.value) == [2])
        #expect(throttle.pending.isEmpty)
        // Taking it counts as a write.
        #expect(offer(&throttle, 3, "clock", at: 61) == nil)
    }

    @Test func flushingTakesEverythingPending() {
        var throttle = DiskWriteThrottle<String, Int>(interval: .seconds(60))
        _ = offer(&throttle, 1, "a", at: 0)
        _ = offer(&throttle, 2, "a", at: 1)
        _ = offer(&throttle, 1, "b", at: 0)
        _ = offer(&throttle, 2, "b", at: 2)
        let flushed = throttle.takeAll(now: s(3))
        #expect(Dictionary(uniqueKeysWithValues: flushed.map { ($0.key, $0.value) }) == ["a": 2, "b": 2])
        #expect(throttle.pending.isEmpty)
        let again = throttle.takeAll(now: s(4))
        #expect(again.isEmpty)
        // A flush counts as a write: the next change is held back again.
        #expect(offer(&throttle, 3, "a", at: 5) == nil)
    }

    @Test func periodicChoresRunFirstThenOncePerInterval() {
        var prune = PeriodicSchedule(interval: .seconds(24 * 3600))
        let runs = [0, 1, 24 * 3600 - 1, 24 * 3600, 24 * 3600 + 10].map { prune.runIfDue(now: s($0)) }
        #expect(runs == [true, false, false, true, false])
    }
}
