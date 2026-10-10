import CoreGraphics
import Testing
@testable import FrostCore

/// `OwnItemPlacement`: when one of Frost's own status items counts as placed next to its anchor.
///
/// The rule is adjacency rather than order, because the system leaves a blank gap between adjacent status items
/// (measured on macOS 27: frames 1148/1172 for 10 pt wide dividers) and while a divider is being dragged into place
/// the two are often within a point of each other. A strict order comparison called a placement that had worked a
/// failure.
@Suite struct OwnItemPlacementTests {
    private let anchor = CGRect(x: 1000, y: 0, width: 10, height: 30)

    @Test func anItemTouchingTheAnchorCounts() {
        #expect(OwnItemPlacement.isSatisfied(item: CGRect(x: 1010, y: 0, width: 10, height: 30),
                                             anchor: anchor, side: .right))
        #expect(OwnItemPlacement.isSatisfied(item: CGRect(x: 990, y: 0, width: 10, height: 30),
                                             anchor: anchor, side: .left))
    }

    /// The measured blank gap between adjacent status items must not read as "not placed".
    @Test func theSystemsBlankGapStillCounts() {
        #expect(OwnItemPlacement.isSatisfied(item: CGRect(x: 1024, y: 0, width: 10, height: 30),
                                             anchor: anchor, side: .right))
        #expect(OwnItemPlacement.isSatisfied(item: CGRect(x: 976, y: 0, width: 10, height: 30),
                                             anchor: anchor, side: .left))
    }

    @Test func anItemLeftElsewhereIsNotPlaced() {
        #expect(!OwnItemPlacement.isSatisfied(item: CGRect(x: 500, y: 0, width: 10, height: 30),
                                              anchor: anchor, side: .right))
        #expect(!OwnItemPlacement.isSatisfied(item: CGRect(x: 1500, y: 0, width: 10, height: 30),
                                              anchor: anchor, side: .left))
    }

    /// The wrong side is a failure even when the item is right next to the anchor.
    @Test func theWrongSideIsNotPlaced() {
        #expect(!OwnItemPlacement.isSatisfied(item: CGRect(x: 990, y: 0, width: 10, height: 30),
                                              anchor: anchor, side: .right))
        #expect(!OwnItemPlacement.isSatisfied(item: CGRect(x: 1010, y: 0, width: 10, height: 30),
                                              anchor: anchor, side: .left))
    }

    /// Two dividers dropped on top of each other: their order is a coin flip, but they are placed.
    @Test func overlappingItemsCount() {
        #expect(OwnItemPlacement.isSatisfied(item: CGRect(x: 1001, y: 0, width: 10, height: 30),
                                             anchor: anchor, side: .right))
    }
}

