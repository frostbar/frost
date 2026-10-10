import Testing
@testable import FrostCore

/// Lifting a glyph out of an opaque menu bar strip capture (`StripGlyphExtraction`), which is how macOS 27 gets icon
/// images: the bar is a blurred translucent material, so the background under a crop is nearly flat while the glyph
/// deviates strongly from it.
@Suite struct StripGlyphExtractionTests {
    private let width = 16, height = 12

    /// A crop with a uniform background and a dark square in the middle (a glyph), in BGRA memory order.
    private func crop(background: (UInt8, UInt8, UInt8), glyph: (UInt8, UInt8, UInt8)?,
                      glyphRect: (x: Int, y: Int, w: Int, h: Int) = (6, 4, 4, 4)) -> StripGlyphExtraction.Buffer {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let inside = glyphRect.x..<(glyphRect.x + glyphRect.w) ~= x
                    && glyphRect.y..<(glyphRect.y + glyphRect.h) ~= y
                let colour = (inside ? glyph : nil) ?? background
                let o = (y * width + x) * 4
                bytes[o] = colour.2; bytes[o + 1] = colour.1; bytes[o + 2] = colour.0; bytes[o + 3] = 255
            }
        }
        return StripGlyphExtraction.Buffer(bytes: bytes, width: width, height: height)
    }

    private func alpha(_ buffer: StripGlyphExtraction.Buffer, _ x: Int, _ y: Int) -> UInt8 {
        buffer.bytes[(y * buffer.width + x) * 4 + 3]
    }

    @Test func theGlyphComesOutOnAlphaAndTheBackgroundDoesNot() throws {
        let extracted = try #require(StripGlyphExtraction.extract(crop(background: (240, 235, 210),
                                                                       glyph: (20, 20, 20))))
        #expect(alpha(extracted.buffer, 0, 0) == 0)
        #expect(alpha(extracted.buffer, 15, 11) == 0)
        #expect(alpha(extracted.buffer, 7, 5) == 255)
        #expect(StripGlyphExtraction.isItemDrawn(extracted))
        // The glyph's own colour survives (dark, in premultiplied BGRA).
        let o = (5 * width + 7) * 4
        #expect(extracted.buffer.bytes[o] < 30)
    }

    /// A light glyph on a dark bar (a white icon over a dark wallpaper) keeps its colour rather than being inverted.
    @Test func aLightGlyphKeepsItsColour() throws {
        let extracted = try #require(StripGlyphExtraction.extract(crop(background: (30, 30, 30),
                                                                       glyph: (250, 250, 250))))
        let o = (5 * width + 7) * 4
        #expect(alpha(extracted.buffer, 7, 5) == 255)
        #expect(extracted.buffer.bytes[o] > 200)
    }

    /// The bar blurs the wallpaper, so the background can slope from the top of the crop to its bottom: the estimate
    /// interpolates between the two margins instead of using one value, and a sloping background must not read as
    /// glyph along the crop's edge.
    @Test func aSlopingBackgroundIsNotMistakenForGlyph() throws {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let level = UInt8(200 - y * 4)
            for x in 0..<width {
                let o = (y * width + x) * 4
                bytes[o] = level; bytes[o + 1] = level; bytes[o + 2] = level; bytes[o + 3] = 255
            }
        }
        let extracted = try #require(StripGlyphExtraction.extract(.init(bytes: bytes, width: width, height: height)))
        for y in 0..<height {
            for x in 0..<width { #expect(alpha(extracted.buffer, x, y) == 0) }
        }
        #expect(!StripGlyphExtraction.isItemDrawn(extracted))
    }

    /// A frame the bar doesn't draw crops to background only: no image, and the item keeps its app icon.
    @Test func anEmptyCropIsNotAnItem() throws {
        let extracted = try #require(StripGlyphExtraction.extract(crop(background: (240, 235, 210), glyph: nil)))
        #expect(extracted.coverage == 0)
        #expect(!StripGlyphExtraction.isItemDrawn(extracted))
    }

    @Test func impossibleBuffersAreRejected() {
        #expect(StripGlyphExtraction.extract(.init(bytes: [], width: 0, height: 0)) == nil)
        #expect(StripGlyphExtraction.extract(.init(bytes: [0, 0, 0, 0], width: 1, height: 1)) == nil)
        #expect(StripGlyphExtraction.extract(.init(bytes: [UInt8](repeating: 0, count: 40), width: 4, height: 8)) == nil)
    }
}
