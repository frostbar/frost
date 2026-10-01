import Testing
import CoreGraphics
@testable import FrostCore

@Suite struct FlowRowsTests {
    @Test func emptyInputHasNoRows() {
        #expect(FlowRows.pack([], maxWidth: 100, spacing: 4).isEmpty)
        #expect(FlowRows.size([], maxWidth: 100, spacing: 4, rowHeight: 36, lineSpacing: 4) == .zero)
    }

    @Test func fillsRowsUpToMaxWidthThenWraps() {
        // 5 × 40 + 4 × 4 = 216: exactly 5 fit in a row, the 6th wraps.
        let widths = [CGFloat](repeating: 40, count: 7)
        #expect(FlowRows.pack(widths, maxWidth: 216, spacing: 4) == [0..<5, 5..<7])
    }

    @Test func wideItemWrapsNaturally() {
        // 40, 40, 100 (doesn't fit: 40+4+40+4+100 = 188 > 160) → wrap; 100 + 4 + 40 = 144 ≤ 160.
        let rows = FlowRows.pack([40, 40, 100, 40], maxWidth: 160, spacing: 4)
        #expect(rows == [0..<2, 2..<4])
    }

    @Test func itemWiderThanMaxWidthGetsItsOwnRow() {
        let rows = FlowRows.pack([40, 300, 40], maxWidth: 200, spacing: 4)
        #expect(rows == [0..<1, 1..<2, 2..<3])
    }

    @Test func sizeIsWidestRowAndStackedHeight() {
        let widths: [CGFloat] = [40, 40, 100, 40]
        let size = FlowRows.size(widths, maxWidth: 160, spacing: 4, rowHeight: 36, lineSpacing: 6)
        // Row widths 84 and 144; height of two rows 36 + 6 + 36.
        #expect(size == CGSize(width: 144, height: 78))
    }

    @Test func toleratesFloatingPointNoise() {
        // Re-laying out with the row width itself as the limit gives the same result (`Layout.placeSubviews`
        // re-lays out using the bounds width).
        let widths: [CGFloat] = [33.3, 33.3, 33.3]
        let size = FlowRows.size(widths, maxWidth: 200, spacing: 4.1, rowHeight: 10, lineSpacing: 0)
        #expect(FlowRows.pack(widths, maxWidth: size.width, spacing: 4.1) == [0..<3])
    }
}
