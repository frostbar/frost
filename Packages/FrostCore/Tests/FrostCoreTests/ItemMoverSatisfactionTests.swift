import CoreGraphics
import Testing
@testable import FrostCore

/// Whether a macOS 27 move has arrived (`ItemMover.isSatisfiedOn27`).
///
/// A drop at the *end* of a section is resolved against one of Frost's own dividers, which is an invisible 8 pt line
/// while the layout editor is open. The relaxed check for it has to mean "the last icon of that section" — an
/// "anywhere on the divider's side" check would call a drop that moved nothing a success.
@Suite struct ItemMoverSatisfactionTests {
    private let itemID: CGWindowID = 10
    private let otherID: CGWindowID = 11
    private let dividerID: CGWindowID = 20
    private let iconID: CGWindowID = 21
    private let controls = FrostControlWindows(icon: 21, hiddenSeparator: 20, alwaysHiddenSeparator: 22)

    private func frames(_ entries: [CGWindowID: CGFloat]) -> [CGWindowID: CGRect] {
        entries.mapValues { CGRect(x: $0, y: 0, width: 30, height: 24) }
    }

    /// Already the last icon before the divider: nothing to do.
    @Test func beingTheLastIconBeforeTheDividerIsSatisfied() {
        let layout = frames([itemID: 100, dividerID: 200])
        #expect(ItemMover.isSatisfiedOn27(itemID, .leftOf(dividerID), frames: layout, controls: controls))
    }

    /// The bug this rule was rewritten for: an icon that is already in the section but *not* at its end has not
    /// arrived — reporting it as arrived made the editor show no change at all after a drop.
    @Test func anIconWithAnotherIconBehindItHasNotArrived() {
        let layout = frames([itemID: 100, otherID: 150, dividerID: 200])
        #expect(!ItemMover.isSatisfiedOn27(itemID, .leftOf(dividerID), frames: layout, controls: controls))
    }

    /// Frost's own items are not "another icon of the user's": a divider between the icon and the target divider
    /// doesn't stop it from having arrived.
    @Test func ownItemsDoNotCountAsIconsInBetween() {
        let layout = frames([itemID: 100, 22: 150, dividerID: 200])
        #expect(ItemMover.isSatisfiedOn27(itemID, .leftOf(dividerID), frames: layout, controls: controls))
    }

    /// An icon on the divider's other side has not arrived, wherever it is.
    @Test func anIconOnTheWrongSideHasNotArrived() {
        let layout = frames([dividerID: 200, itemID: 300])
        #expect(!ItemMover.isSatisfiedOn27(itemID, .leftOf(dividerID), frames: layout, controls: controls))
    }

    /// A destination that is an ordinary icon keeps the strict rule, either side. That rule is about *order*, not
    /// distance: the frames it reads on macOS 26 come from contiguous windows, so the next item in the order is the
    /// neighbour whatever the gap.
    @Test func iconDestinationsKeepTheStrictRule() {
        let itemRightOfOther = frames([otherID: 100, itemID: 130])
        #expect(ItemMover.isSatisfiedOn27(itemID, .rightOf(otherID), frames: itemRightOfOther, controls: controls))

        let itemLeftOfOther = frames([itemID: 100, otherID: 130])
        #expect(ItemMover.isSatisfiedOn27(itemID, .leftOf(otherID), frames: itemLeftOfOther, controls: controls))

        // A third item in between: not the neighbour, so not arrived, however close the two ends up.
        let third: CGWindowID = 12
        let withAThirdItemBetween = frames([otherID: 100, third: 110, itemID: 120])
        #expect(!ItemMover.isSatisfiedOn27(itemID, .rightOf(otherID), frames: withAThirdItemBetween,
                                           controls: controls))
    }

    /// Without the control items there is nothing to relax, so the strict rule applies — which for an icon that is
    /// immediately left of the (here unidentified) divider is satisfied anyway.
    @Test func withoutControlsTheStrictRuleApplies() {
        let immediatelyLeft = frames([itemID: 100, dividerID: 200])
        #expect(ItemMover.isSatisfiedOn27(itemID, .leftOf(dividerID), frames: immediatelyLeft, controls: nil))

        let withAnotherIconBehind = frames([itemID: 100, otherID: 150, dividerID: 200])
        #expect(!ItemMover.isSatisfiedOn27(itemID, .leftOf(dividerID), frames: withAnotherIconBehind, controls: nil))
    }
}
