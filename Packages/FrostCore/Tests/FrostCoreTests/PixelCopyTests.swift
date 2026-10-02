import CoreGraphics
import Foundation
import Testing
@testable import FrostCore

@Suite struct PixelCopyVisibilityTests {
    private static func image(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context)
        return context.makeImage()!
    }

    /// A capture of a window caught mid-move (or not drawn yet) is fully transparent: it must not replace a tile's
    /// image (the tile would go blank).
    @Test func fullyTransparentCapturesHaveNoVisiblePixels() throws {
        let blank = Self.image(width: 8, height: 4) { _ in }
        #expect(try #require(PixelCopy(blank)).hasVisiblePixels == false)
    }

    @Test func aSingleVisiblePixelCounts() throws {
        let dot = Self.image(width: 8, height: 4) { context in
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.2))
            context.fill(CGRect(x: 7, y: 3, width: 1, height: 1))
        }
        #expect(try #require(PixelCopy(dot)).hasVisiblePixels)
    }

    @Test func alphaIsTheLastByteOfEachPixel() {
        #expect(PixelCopy.hasVisiblePixels(Data([255, 255, 255, 0, 255, 255, 255, 0])) == false)
        #expect(PixelCopy.hasVisiblePixels(Data([0, 0, 0, 0, 0, 0, 0, 1])))
    }
}
