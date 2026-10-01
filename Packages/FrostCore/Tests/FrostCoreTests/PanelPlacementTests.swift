import Testing
import CoreGraphics
@testable import FrostCore

@Suite struct PanelPlacementTests {
    // Notched display example (AppKit coordinates): 1800×1169, 39 pt menu bar, Dock at the bottom.
    let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    let visible = CGRect(x: 0, y: 80, width: 1800, height: 1050)

    @Test func maxContentWidthLeavesMarginOnBothSides() {
        #expect(PanelPlacement.maxContentWidth(visibleFrame: visible) == 1784)
        #expect(PanelPlacement.maxContentWidth(visibleFrame: CGRect(x: 0, y: 0, width: 10, height: 10)) == 0)
    }

    @Test func maxContentHeightRunsFromBelowMenuBarToBottomMargin() {
        // Content top edge 1169 − 39 − 6 = 1124, bottom edge no lower than 80 + 8 = 88.
        #expect(PanelPlacement.maxContentHeight(screenFrame: screen, visibleFrame: visible, menuBarHeight: 39) == 1036)
    }

    @Test func menuBarHeightUsesScreenGeometry() {
        #expect(PanelPlacement.menuBarHeight(screenFrame: screen, visibleFrame: visible, fallback: 24) == 39)
        // Auto-hiding menu bar: visibleFrame reaches the top of the screen.
        let autoHide = CGRect(x: 0, y: 80, width: 1800, height: 1089)
        #expect(PanelPlacement.menuBarHeight(screenFrame: screen, visibleFrame: autoHide, fallback: 24) == 24)
    }

    @Test func trailingEdgeAlignsWithAnchorBelowMenuBar() {
        let frame = PanelPlacement.frame(size: CGSize(width: 224, height: 100), inset: 12, anchorMaxX: 1400,
                                         screenFrame: screen, visibleFrame: visible, menuBarHeight: 39)
        // Content width 200, right edge 1400 → content x 1200, window x 1188. Content top edge = 1169 − 39 − 6 = 1124,
        // window top edge 1136.
        #expect(frame == CGRect(x: 1188, y: 1036, width: 224, height: 100))
    }

    @Test func growingContentKeepsTopAndTrailingEdgesFixed() {
        let small = PanelPlacement.frame(size: CGSize(width: 224, height: 100), inset: 12, anchorMaxX: 1400,
                                         screenFrame: screen, visibleFrame: visible, menuBarHeight: 39)
        let large = PanelPlacement.frame(size: CGSize(width: 300, height: 180), inset: 12, anchorMaxX: 1400,
                                         screenFrame: screen, visibleFrame: visible, menuBarHeight: 39)
        #expect(small.maxX == large.maxX)
        #expect(small.maxY == large.maxY)
    }

    @Test func clampsNearRightEdge() {
        let frame = PanelPlacement.frame(size: CGSize(width: 324, height: 80), inset: 12, anchorMaxX: 1798,
                                         screenFrame: screen, visibleFrame: visible, menuBarHeight: 39)
        // Content width 300, right edge at most 1792 → content x 1492.
        #expect(frame.minX + 12 == 1492)
        #expect(frame.maxX - 12 == 1792)
    }

    @Test func clampsNearLeftEdgeOfOffsetScreen() {
        // Secondary display on the right, top edges aligned: AppKit y = 1169 − 1080 = 89, 30 pt menu bar.
        let other = CGRect(x: 1800, y: 89, width: 1920, height: 1080)
        let otherVisible = CGRect(x: 1800, y: 89, width: 1920, height: 1050)
        let frame = PanelPlacement.frame(size: CGSize(width: 224, height: 80), inset: 12, anchorMaxX: 1850,
                                         screenFrame: other, visibleFrame: otherVisible, menuBarHeight: 30)
        #expect(frame.minX + 12 == 1808)
        // Content top edge = 1169 − 30 − 6 = 1133; the window top edge adds the 12 pt margin.
        #expect(frame.maxY == CGFloat(1145))
    }

    @Test func tooWideContentStartsAtLeftMargin() {
        let frame = PanelPlacement.frame(size: CGSize(width: 2000, height: 80), inset: 12, anchorMaxX: 1000,
                                         screenFrame: screen, visibleFrame: visible, menuBarHeight: 39)
        #expect(frame.minX + 12 == 8)
    }

    @Test func topInsetEqualToGapPutsWindowTopAtMenuBarBottom() {
        // Top margin = the 6 pt gap: the window's top edge is exactly the menu bar's bottom edge (1169 − 39 = 1130),
        // so the shadow is not drawn into the menu bar.
        let frame = PanelPlacement.frame(size: CGSize(width: 224, height: 100), inset: 40, topInset: 6, anchorMaxX: 1400,
                                         screenFrame: screen, visibleFrame: visible, menuBarHeight: 39)
        #expect(frame.maxY == CGFloat(1130))
        // Horizontally it still uses the 40 pt left/right margins.
        #expect(frame.maxX - 40 == 1400)
    }
}
