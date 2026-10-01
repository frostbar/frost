import Testing
@testable import FrostCore

@MainActor @Suite struct RefreshCoalescerTests {
    /// Counts runs; each run parks on `gate` until the test releases it.
    @MainActor final class Probe {
        var runs = 0
        var gate: CheckedContinuation<Void, Never>?

        func run() async {
            runs += 1
            await withCheckedContinuation { gate = $0 }
        }

        func release() {
            let gate = gate
            self.gate = nil
            gate?.resume()
        }
    }

    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
    }

    @Test func refreshRunsOnceWhenIdle() async {
        let probe = Probe()
        let coalescer = RefreshCoalescer { await probe.run() }
        let request = Task { await coalescer.refresh() }
        await waitUntil { probe.gate != nil }
        #expect(coalescer.isRunning)
        probe.release()
        await request.value
        #expect(probe.runs == 1)
        #expect(!coalescer.isRunning)
    }

    @Test func requestsDuringARunShareOneFollowUpRun() async {
        let probe = Probe()
        let coalescer = RefreshCoalescer { await probe.run() }
        coalescer.refreshInBackground()
        await waitUntil { probe.gate != nil }
        // The run in flight may have read its data before the requests: both requests must wait for a new run,
        // but they share the same one.
        let a = Task { await coalescer.refresh() }
        let b = Task { await coalescer.refresh() }
        for _ in 0..<50 { await Task.yield() }
        #expect(probe.runs == 1)
        probe.release()
        await waitUntil { probe.runs == 2 && probe.gate != nil }
        #expect(probe.runs == 2)
        probe.release()
        await a.value
        await b.value
        #expect(probe.runs == 2)
    }

    @Test func backgroundRequestsDuringARunAreDropped() async {
        let probe = Probe()
        let coalescer = RefreshCoalescer { await probe.run() }
        coalescer.refreshInBackground()
        await waitUntil { probe.gate != nil }
        coalescer.refreshInBackground()
        coalescer.refreshInBackground()
        probe.release()
        await waitUntil { !coalescer.isRunning }
        #expect(probe.runs == 1)
    }
}
