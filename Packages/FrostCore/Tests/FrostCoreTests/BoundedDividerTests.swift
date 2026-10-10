import CoreGraphics
import Testing
@testable import FrostCore

/// The divider widths macOS 27 honours, and the bound that keeps Frost inside them (`BoundedDivider`).
@Suite struct BoundedDividerTests {
    /// Measured: a divider is honoured up to just under half the display; at half (864 pt on a 1728 pt display) and
    /// above, the width was ignored and nothing left the bar.
    @Test func collapseWidthStaysUnderHalfTheDisplay() {
        #expect(BoundedDivider.collapseWidth(displayWidth: 1728) == 832)
        #expect(BoundedDivider.collapseWidth(displayWidth: 1440) == 688)
        #expect(BoundedDivider.collapseWidth(displayWidth: 1200) == 568)
    }

    /// A very wide display doesn't get a very wide divider: the request is capped, since only the *fraction* of the
    /// display was measured.
    @Test func collapseWidthIsCapped() {
        #expect(BoundedDivider.collapseWidth(displayWidth: 5120) == BoundedDivider.absoluteCap)
    }

    /// A display too narrow for a useful divider gets none, and the caller keeps the divider narrow instead of
    /// pretending to hide something.
    @Test func narrowDisplaysGetNoCollapseWidth() {
        #expect(BoundedDivider.collapseWidth(displayWidth: 400) == nil)
        #expect(BoundedDivider.collapseWidth(displayWidth: 100) == nil)
    }

    /// The bound is the one the system enforces: at or above half the display the width does nothing.
    @Test func widthsAtOrAboveHalfTheDisplayAreNotEffective() {
        #expect(BoundedDivider.isEffective(width: 800, displayWidth: 1728))
        #expect(!BoundedDivider.isEffective(width: 864, displayWidth: 1728))
        #expect(!BoundedDivider.isEffective(width: 1600, displayWidth: 1728))
        #expect(!BoundedDivider.isEffective(width: 100, displayWidth: 1728))
    }

    /// Every width the rule returns is one it accepts.
    @Test func theChosenWidthIsAlwaysEffective() throws {
        for displayWidth in stride(from: 500.0, through: 6000.0, by: 100.0) {
            guard let width = BoundedDivider.collapseWidth(displayWidth: displayWidth) else { continue }
            #expect(BoundedDivider.isEffective(width: width, displayWidth: displayWidth))
        }
    }
}
