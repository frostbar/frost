import CoreGraphics
import Testing
@testable import FrostCore

@Suite struct ScreenGeometryTests {
    @Test func convertsAppKitPointsToCGCoordinates() {
        // Main display is 1117 tall: AppKit y = 1117 (top edge) → CG y = 0; AppKit y = 0 (bottom edge) → CG y = 1117.
        #expect(ScreenCoordinates.cgPoint(fromAppKit: CGPoint(x: 5, y: 1117), primaryScreenMaxY: 1117)
            == CGPoint(x: 5, y: 0))
        #expect(ScreenCoordinates.cgPoint(fromAppKit: CGPoint(x: 5, y: 0), primaryScreenMaxY: 1117)
            == CGPoint(x: 5, y: 1117))
        // A secondary display below the main one: negative AppKit y → CG y beyond the main display's height.
        #expect(ScreenCoordinates.cgPoint(fromAppKit: CGPoint(x: 5, y: -100), primaryScreenMaxY: 1117)
            == CGPoint(x: 5, y: 1217))
    }

    @Test func convertsRectsBothWays() {
        // A 30 pt menu bar item at the top of a 1117 pt tall main display.
        let appKit = CGRect(x: 1490, y: 1087, width: 30, height: 30)
        let cg = ScreenCoordinates.cgRect(fromAppKit: appKit, primaryScreenMaxY: 1117)
        #expect(cg == CGRect(x: 1490, y: 0, width: 30, height: 30))
        // The same formula converts back.
        #expect(ScreenCoordinates.cgRect(fromAppKit: cg, primaryScreenMaxY: 1117) == appKit)
    }
}
