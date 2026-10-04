import Foundation
import Testing
@testable import FrostCore

struct FrostBarIconClickTests {
    private let now = ContinuousClock.now

    private func decide(_ phase: FrostBarIconClick.Phase, option: Bool = false,
                        showingAlwaysHidden: Bool = false) -> FrostBarIconClick.Action {
        FrostBarIconClick.decide(phase: phase, option: option, showingAlwaysHidden: showingAlwaysHidden, now: now)
    }

    @Test func closedPanelOpens() {
        #expect(decide(.closed) == .open(showAlwaysHidden: false))
        #expect(decide(.closed, option: true) == .open(showAlwaysHidden: true))
    }

    /// The open waits for a lingering item to move back (the panel isn't on screen yet): a second click must not close
    /// (and cancel) an open the user can't see yet.
    @Test func clickWhileOpeningKeepsOpening() {
        #expect(decide(.opening) == .keepOpening(showAlwaysHidden: nil))
        #expect(decide(.opening, option: true) == .keepOpening(showAlwaysHidden: true))
    }

    /// A click right after the panel appeared was made before the user could see it.
    @Test func clickJustAfterPresentingIsIgnored() {
        let shown = now - .milliseconds(100)
        #expect(decide(.presented(at: shown)) == .keepOpening(showAlwaysHidden: nil))
        #expect(decide(.presented(at: shown), option: true) == .keepOpening(showAlwaysHidden: true))
    }

    @Test func clickOnShownPanelCloses() {
        let shown = now - FrostBarIconClick.reactionGrace
        #expect(decide(.presented(at: shown)) == .close)
        #expect(decide(.presented(at: now - .seconds(5))) == .close)
    }

    @Test func optionClickOnShownPanelTogglesAlwaysHidden() {
        let shown = now - .seconds(5)
        #expect(decide(.presented(at: shown), option: true) == .setAlwaysHidden(true))
        #expect(decide(.presented(at: shown), option: true, showingAlwaysHidden: true) == .setAlwaysHidden(false))
    }
}

struct LingerReturnAnchorTests {
    @Test func iconTakesTheRightEdgeOfItsNeighbor() {
        let icon = CGRect(x: 1390, y: 0, width: 30, height: 24)
        let item = CGRect(x: 1424, y: 0, width: 36, height: 24)
        #expect(LingerReturnAnchor.iconMaxX(icon: icon, item: item) == 1460)
    }

    @Test func notTheNeighborGivesNoPrediction() {
        let icon = CGRect(x: 1390, y: 0, width: 30, height: 24)
        #expect(LingerReturnAnchor.iconMaxX(icon: icon, item: CGRect(x: 1500, y: 0, width: 36, height: 24)) == nil)
        #expect(LingerReturnAnchor.iconMaxX(icon: icon, item: CGRect(x: 1300, y: 0, width: 36, height: 24)) == nil)
        #expect(LingerReturnAnchor.iconMaxX(icon: icon, item: CGRect(x: 1424, y: 0, width: 0, height: 24)) == nil)
    }
}
