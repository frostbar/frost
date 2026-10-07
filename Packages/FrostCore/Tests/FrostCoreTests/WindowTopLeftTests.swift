import Testing
import CoreGraphics
@testable import FrostCore

@Suite struct WindowTopLeftTests {
    /// A 1728×1080 screen below a 30 pt menu bar (AppKit coordinates).
    let screen = CGRect(x: 0, y: 0, width: 1728, height: 1050)

    @Test func theTopLeftCornerStaysPutWhateverTheHeight() {
        let topLeft = CGPoint(x: 500, y: 900)
        let short = WindowTopLeft.frame(size: CGSize(width: 520, height: 400), topLeft: topLeft, visibleFrames: [screen])
        let tall = WindowTopLeft.frame(size: CGSize(width: 520, height: 600), topLeft: topLeft, visibleFrames: [screen])
        #expect(short == CGRect(x: 500, y: 500, width: 520, height: 400))
        #expect(tall == CGRect(x: 500, y: 300, width: 520, height: 600))
    }

    @Test func aWindowThatWouldStickOutIsKeptOnScreen() {
        // Too low for the taller tab: moved up just enough; too far right: moved left.
        let frame = WindowTopLeft.frame(size: CGSize(width: 520, height: 600), topLeft: CGPoint(x: 1500, y: 400),
                                        visibleFrames: [screen])
        #expect(frame == CGRect(x: 1208, y: 0, width: 520, height: 600))
    }

    @Test func aCornerOnNoScreenIsCenteredByTheCaller() {
        // The display it was on is gone.
        #expect(WindowTopLeft.frame(size: CGSize(width: 520, height: 400), topLeft: CGPoint(x: 2500, y: 900),
                                    visibleFrames: [screen]) == nil)
    }

    @Test func picksTheScreenTheCornerIsOn() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1050)
        let frame = WindowTopLeft.frame(size: CGSize(width: 520, height: 400), topLeft: CGPoint(x: -1000, y: 800),
                                        visibleFrames: [screen, left])
        #expect(frame == CGRect(x: -1000, y: 400, width: 520, height: 400))
    }

    @Test func roundTrips() {
        #expect(WindowTopLeft.decode(WindowTopLeft.encode(CGPoint(x: -12.5, y: 900))) == CGPoint(x: -12.5, y: 900))
        #expect(WindowTopLeft.decode("garbage") == nil)
        #expect(WindowTopLeft.decode(nil) == nil)
    }
}
