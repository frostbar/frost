import Foundation
import Testing
@testable import FrostCore

@Suite struct RelaunchResumeTests {
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func makeDefaults() -> UserDefaults {
        let name = "RelaunchResumeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - Encoding

    @Test func storedValueRoundTrips() {
        for window in [ResumeWindow.onboarding, .settings(tab: "about"), .settings(tab: "layout")] {
            #expect(ResumeWindow(storedValue: window.storedValue) == window)
        }
    }

    @Test func unknownStoredValuesAreIgnored() {
        #expect(ResumeWindow(storedValue: "") == nil)
        #expect(ResumeWindow(storedValue: "settings:") == nil)
        #expect(ResumeWindow(storedValue: "something") == nil)
    }

    // MARK: - Decision on termination

    @Test func nothingIsRestoredWithoutAPendingScreenRecordingRequest() {
        #expect(RelaunchResume.windowToRestore(screenRecordingPending: false,
                                               visibleFrontToBack: [.settings(tab: "about")]) == nil)
    }

    @Test func nothingIsRestoredWhenNoFrostWindowIsVisible() {
        #expect(RelaunchResume.windowToRestore(screenRecordingPending: true, visibleFrontToBack: []) == nil)
    }

    @Test func theFrontmostVisibleWindowIsRestored() {
        #expect(RelaunchResume.windowToRestore(screenRecordingPending: true,
                                               visibleFrontToBack: [.settings(tab: "about"), .onboarding])
            == .settings(tab: "about"))
        #expect(RelaunchResume.windowToRestore(screenRecordingPending: true,
                                               visibleFrontToBack: [.onboarding, .settings(tab: "layout")])
            == .onboarding)
    }

    // MARK: - Storage

    @Test func aRecordedWindowIsConsumedOnce() {
        let defaults = makeDefaults()
        RelaunchResume.record(.settings(tab: "about"), in: defaults, at: now)
        #expect(RelaunchResume.consume(from: defaults, now: now.addingTimeInterval(3)) == .settings(tab: "about"))
        #expect(RelaunchResume.consume(from: defaults, now: now.addingTimeInterval(4)) == nil)
    }

    @Test func nothingRecordedConsumesNothing() {
        #expect(RelaunchResume.consume(from: makeDefaults(), now: now) == nil)
    }

    @Test func aStaleRecordIsDiscarded() {
        // A relaunch reopens Frost within seconds; a record found much later (Frost quit and was launched again by
        // hand, or at login) must not reopen a window.
        let defaults = makeDefaults()
        RelaunchResume.record(.onboarding, in: defaults, at: now)
        #expect(RelaunchResume.consume(from: defaults, now: now.addingTimeInterval(RelaunchResume.maxAge + 1)) == nil)
        #expect(RelaunchResume.consume(from: defaults, now: now) == nil)
    }

    @Test func aRecordFromTheFutureIsDiscarded() {
        // The clock went back (or the record is corrupt): don't trust it.
        let defaults = makeDefaults()
        RelaunchResume.record(.onboarding, in: defaults, at: now)
        #expect(RelaunchResume.consume(from: defaults, now: now.addingTimeInterval(-60)) == nil)
    }

    @Test func theLegacyOnboardingFlagIsCleared() {
        // Versions up to 0.3.0 wrote a bool before relaunching from onboarding.
        let defaults = makeDefaults()
        defaults.set(true, forKey: RelaunchResume.legacyOnboardingKey)
        #expect(RelaunchResume.consume(from: defaults, now: now) == .onboarding)
        #expect(defaults.object(forKey: RelaunchResume.legacyOnboardingKey) == nil)
    }
}
