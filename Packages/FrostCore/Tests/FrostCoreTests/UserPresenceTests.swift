import Testing
@testable import FrostCore

@Suite struct UserPresenceTests {
    /// Applies the update and returns whether `isAway` changed (`#expect` can't wrap a mutating call).
    func update(_ presence: inout UserPresence, _ reason: UserPresence.Reason, _ active: Bool) -> Bool {
        presence.update(reason, active)
    }

    @Test func presentByDefault() {
        #expect(!UserPresence().isAway)
    }

    @Test func anyReasonMakesTheUserAway() {
        for reason in UserPresence.Reason.allCases {
            var presence = UserPresence()
            #expect(update(&presence, reason, true))
            #expect(presence.isAway)
            #expect(update(&presence, reason, false))
            #expect(!presence.isAway)
        }
    }

    @Test func staysAwayUntilEveryReasonEnded() {
        // Lock the screen, then the displays sleep; waking the displays shows the lock screen: still away.
        var presence = UserPresence()
        #expect(update(&presence, .screenLocked, true))
        #expect(!update(&presence, .displaysAsleep, true))
        #expect(!update(&presence, .displaysAsleep, false))
        #expect(presence.isAway)
        #expect(update(&presence, .screenLocked, false))
        #expect(!presence.isAway)
    }

    @Test func repeatedNotificationsDoNotFlipTheState() {
        var presence = UserPresence()
        #expect(update(&presence, .sessionInactive, true))
        #expect(!update(&presence, .sessionInactive, true))
        #expect(update(&presence, .sessionInactive, false))
        #expect(!update(&presence, .sessionInactive, false))
        // An unmatched "ended" (e.g. Frost launched while the screen was locked and missed the start) is harmless.
        #expect(!update(&presence, .screenLocked, false))
    }
}
