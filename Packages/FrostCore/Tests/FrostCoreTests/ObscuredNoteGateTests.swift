import Testing
@testable import FrostCore

@Suite struct ObscuredNoteGateTests {
    private func gate() -> ObscuredNoteGate { ObscuredNoteGate(showDelay: 5, hideDelay: 10) }

    @Test func staysHiddenWithoutObscuredItems() {
        var gate = gate()
        for t in stride(from: 0.0, through: 30, by: 2) { #expect(gate.update(rawCount: 0, now: t) == 0) }
    }

    @Test func showsOnlyAfterTheCountHeldForTheShowDelay() {
        var gate = gate()
        #expect(gate.update(rawCount: 1, now: 0) == 0)
        #expect(gate.update(rawCount: 1, now: 2) == 0)
        #expect(gate.update(rawCount: 1, now: 4.9) == 0)
        #expect(gate.update(rawCount: 1, now: 5) == 1)
    }

    @Test func aBlinkingItemNeverShowsTheNote() {
        var gate = gate()
        // Off screen for 4 s of every 20 s, sampled every 2 s.
        for cycle in 0..<10 {
            let base = Double(cycle) * 20
            for step in 0..<10 {
                let t = base + Double(step) * 2
                let raw = step < 2 ? 1 : 0
                #expect(gate.update(rawCount: raw, now: t) == 0)
            }
        }
    }

    @Test func aBreakRestartsTheShowDelay() {
        var gate = gate()
        _ = gate.update(rawCount: 1, now: 0)
        _ = gate.update(rawCount: 1, now: 4)
        _ = gate.update(rawCount: 0, now: 5)
        #expect(gate.update(rawCount: 1, now: 6) == 0)
        #expect(gate.update(rawCount: 1, now: 10) == 0)
        #expect(gate.update(rawCount: 1, now: 11) == 1)
    }

    @Test func staysThroughShortGapsAndGoesAfterTheHideDelay() {
        var gate = gate()
        _ = gate.update(rawCount: 2, now: 0)
        #expect(gate.update(rawCount: 2, now: 5) == 2)
        #expect(gate.update(rawCount: 0, now: 6) == 2)
        #expect(gate.update(rawCount: 0, now: 15.9) == 2)
        #expect(gate.update(rawCount: 0, now: 16) == 0)
    }

    @Test func aReturningCountCancelsTheHide() {
        var gate = gate()
        _ = gate.update(rawCount: 1, now: 0)
        _ = gate.update(rawCount: 1, now: 5)
        _ = gate.update(rawCount: 0, now: 6)
        #expect(gate.update(rawCount: 1, now: 12) == 1)
        _ = gate.update(rawCount: 0, now: 13)
        #expect(gate.update(rawCount: 0, now: 22) == 1)
        #expect(gate.update(rawCount: 0, now: 23) == 0)
    }

    @Test func shownNoteFollowsTheLatestCount() {
        var gate = gate()
        _ = gate.update(rawCount: 1, now: 0)
        _ = gate.update(rawCount: 1, now: 5)
        #expect(gate.update(rawCount: 3, now: 7) == 3)
    }

    @Test func resetHidesAtOnce() {
        var gate = gate()
        _ = gate.update(rawCount: 1, now: 0)
        _ = gate.update(rawCount: 1, now: 5)
        gate.reset()
        #expect(gate.count == 0)
        #expect(gate.update(rawCount: 1, now: 6) == 0)
    }
}
