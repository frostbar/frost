import Testing
@testable import FrostCore

@Suite struct SectionStateTests {
    @Test func iconClicksToggleAndOptionExpandsEverything() {
        #expect(SectionState.collapsed.afterIconClick(option: false) == .expanded)
        #expect(SectionState.expanded.afterIconClick(option: false) == .collapsed)
        #expect(SectionState.expandedAll.afterIconClick(option: false) == .collapsed)
        #expect(SectionState.collapsed.afterIconClick(option: true) == .expandedAll)
        #expect(SectionState.expanded.afterIconClick(option: true) == .expandedAll)
        #expect(SectionState.expandedAll.afterIconClick(option: true) == .collapsed)
    }

    @Test func statesAreOrderedByHowMuchIsShown() {
        #expect(SectionState.collapsed < .expanded)
        #expect(SectionState.expanded < .expandedAll)
    }

    @Test func withoutRequestsTheRestoreGoesBackToThePriorState() {
        let expansion = TemporaryExpansion(prior: .collapsed)
        #expect(expansion.userState == .collapsed)
        #expect(expansion.finalState == .collapsed)
    }

    @Test func aClickDuringTheExpansionIsJudgedAgainstTheStateTheUserSees() {
        // The menu bar is temporarily expanded under the freeze frame, but the user sees it collapsed: the click
        // expands it (not "collapse because it's expanded"), and the restore must end expanded.
        var expansion = TemporaryExpansion(prior: .collapsed)
        expansion.iconClicked(option: false)
        #expect(expansion.finalState == .expanded)
        // A second click collapses again.
        expansion.iconClicked(option: false)
        #expect(expansion.finalState == .collapsed)
    }

    @Test func anOptionClickIsNotUndoneByTheRestore() {
        var expansion = TemporaryExpansion(prior: .collapsed)
        expansion.iconClicked(option: true)
        #expect(expansion.finalState == .expandedAll)
    }

    @Test func otherStateRequestsAreRecordedToo() {
        var expansion = TemporaryExpansion(prior: .expanded)
        expansion.request(.collapsed)
        #expect(expansion.userState == .collapsed)
        expansion.iconClicked(option: false)
        #expect(expansion.finalState == .expanded)
    }
}
