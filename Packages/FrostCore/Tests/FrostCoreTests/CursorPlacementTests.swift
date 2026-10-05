import CoreGraphics
import Testing
@testable import FrostCore

struct CursorPlacementTests {
    let saved = CGPoint(x: 700, y: 300)
    let landed = CGRect(x: 1100, y: 0, width: 30, height: 24)

    @Test func backgroundMovesRestoreRightAfterTheDrag() {
        #expect(CursorPlacement.restoresRightAfterDrag(.restore))
        #expect(!CursorPlacement.restoresRightAfterDrag(.onMovedItem))
    }

    @Test func backgroundMoveEndsWhereThePointerWas() {
        #expect(CursorPlacement.finalPosition(.restore, saved: saved, landedItemFrame: landed) == saved)
        #expect(CursorPlacement.finalPosition(.restore, saved: saved, landedItemFrame: nil) == saved)
    }

    @Test func forwardMoveOutEndsOnTheCentreOfTheLandedItem() {
        #expect(CursorPlacement.finalPosition(.onMovedItem, saved: saved, landedItemFrame: landed)
                    == CGPoint(x: 1115, y: 12))
    }

    @Test func forwardMoveOutThatDidNotLandGoesBackToThePointer() {
        #expect(CursorPlacement.finalPosition(.onMovedItem, saved: saved, landedItemFrame: nil) == saved)
    }

    @Test func forwardMoveOutLandedOffScreenGoesBackToThePointer() {
        // Pushed off screen / not on the display: the pointer can't sit on it.
        let offScreen = CGRect(x: -3000, y: 0, width: 30, height: 24)
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(CursorPlacement.finalPosition(.onMovedItem, saved: saved, landedItemFrame: offScreen,
                                              displayBounds: display) == saved)
        #expect(CursorPlacement.finalPosition(.onMovedItem, saved: saved, landedItemFrame: landed,
                                              displayBounds: display) == CGPoint(x: 1115, y: 12))
    }

    @Test func unknownSavedPositionLeavesTheCursorAlone() {
        #expect(CursorPlacement.finalPosition(.restore, saved: nil, landedItemFrame: landed) == nil)
        #expect(CursorPlacement.finalPosition(.onMovedItem, saved: nil, landedItemFrame: nil) == nil)
        // The item's centre is known even without a saved position.
        #expect(CursorPlacement.finalPosition(.onMovedItem, saved: nil, landedItemFrame: landed)
                    == CGPoint(x: 1115, y: 12))
    }

    @Test func pointToRestAtBeforeAForwardedClick() {
        // Elsewhere (the Frost Bar tile): one jump to the item's centre.
        #expect(CursorPlacement.restingPoint(forClickOn: landed, cursor: CGPoint(x: 900, y: 60))
                    == CGPoint(x: 1115, y: 12))
        // Already there (the move out left it on the item): no warp.
        #expect(CursorPlacement.restingPoint(forClickOn: landed, cursor: CGPoint(x: 1115, y: 12)) == nil)
        #expect(CursorPlacement.restingPoint(forClickOn: landed, cursor: CGPoint(x: 1115.3, y: 12.2)) == nil)
    }

    @Test func aClickAwayFromThePointerIsHidden() {
        #expect(CursorPlacement.hidesDuringClick(at: CGPoint(x: 1115, y: 12), cursor: saved))
        #expect(!CursorPlacement.hidesDuringClick(at: CGPoint(x: 1115, y: 12), cursor: CGPoint(x: 1115, y: 12)))
        #expect(!CursorPlacement.hidesDuringClick(at: CGPoint(x: 1115, y: 12), cursor: nil))
    }
}
