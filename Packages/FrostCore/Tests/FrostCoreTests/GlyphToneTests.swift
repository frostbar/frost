import Testing
import CoreGraphics
@testable import FrostCore

/// A synthetic 12×12 capture: transparent background with rectangles / circles drawn as needed. All patterns are
/// symmetric about the center, so reading pixels doesn't need to care about vertical flipping.
private func canvas(_ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: 12, height: 12, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx)
    return ctx.makeImage()!
}

private func fill(_ ctx: CGContext, _ rect: CGRect, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) {
    ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: a))
    ctx.fill(rect)
}

/// RGBA (premultiplied) of pixel (x, y).
private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    let pixels = GlyphPixels.rgba(image)!
    let i = (y * image.width + x) * 4
    return Array(pixels[i..<i + 4])
}

@Suite struct GlyphToneTests {
    func image(white: CGFloat, alpha: CGFloat) -> CGImage {
        canvas { fill($0, CGRect(x: 2, y: 2, width: 8, height: 8), white, white, white, alpha) }
    }

    @Test func whiteGlyphIsLight() { #expect(GlyphTone.of(image(white: 1, alpha: 1)) == .light) }
    @Test func blackGlyphIsDark() { #expect(GlyphTone.of(image(white: 0, alpha: 1)) == .dark) }
    @Test func fullyTransparentDefaultsToLight() { #expect(GlyphTone.of(image(white: 0, alpha: 0)) == .light) }
}

@Suite struct GlyphStyleTests {
    @Test func whiteGlyphIsMonochromeLight() {
        let image = canvas { fill($0, CGRect(x: 2, y: 2, width: 8, height: 8), 1, 1, 1) }
        #expect(GlyphStyle.of(image) == .monochrome(.light))
    }

    @Test func blackGlyphIsMonochromeDark() {
        let image = canvas { fill($0, CGRect(x: 2, y: 2, width: 8, height: 8), 0, 0, 0) }
        #expect(GlyphStyle.of(image) == .monochrome(.dark))
    }

    @Test func antiAliasedGlyphIsMonochrome() {
        // Anti-aliased white circle: semi-transparent white edges plus a grey stroke around it.
        let image = canvas { ctx in
            ctx.setShouldAntialias(true)
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 1.5, y: 1.5, width: 9, height: 9))
            ctx.setStrokeColor(CGColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 0.8))
            ctx.strokeEllipse(in: CGRect(x: 1.5, y: 1.5, width: 9, height: 9))
        }
        #expect(GlyphStyle.of(image) == .monochrome(.light))
    }

    @Test func slightTintFromMenuBarMaterialStaysMonochrome() {
        // The menu bar material may tint the glyph slightly (chroma about 0.1).
        let image = canvas { fill($0, CGRect(x: 2, y: 2, width: 8, height: 8), 0.92, 0.95, 1.0) }
        #expect(GlyphStyle.of(image) == .monochrome(.light))
    }

    @Test func colorfulIconIsColoredWithoutPlate() {
        let image = canvas { ctx in
            fill(ctx, CGRect(x: 2, y: 2, width: 8, height: 4), 0.1, 0.45, 0.95)
            fill(ctx, CGRect(x: 2, y: 6, width: 8, height: 4), 0.95, 0.3, 0.2)
        }
        #expect(GlyphStyle.of(image) == .colored(plate: nil))
    }

    @Test func tinyColoredDotStaysMonochrome() {
        // Only 1 colored pixel among 64 white pixels (< 4%).
        let image = canvas { ctx in
            fill(ctx, CGRect(x: 2, y: 2, width: 8, height: 8), 1, 1, 1)
            fill(ctx, CGRect(x: 5, y: 5, width: 1, height: 1), 1, 0.2, 0.2)
        }
        #expect(GlyphStyle.of(image) == .monochrome(.light))
    }

    @Test func whiteGlyphWithColoredPartNeedsDarkPlate() {
        // White battery outline + green charge level: a colored icon, but its large white area would vanish on
        // light glass.
        let image = canvas { ctx in
            fill(ctx, CGRect(x: 2, y: 2, width: 8, height: 8), 1, 1, 1)
            fill(ctx, CGRect(x: 4, y: 4, width: 4, height: 4), 0.2, 0.8, 0.3)
        }
        #expect(GlyphStyle.of(image) == .colored(plate: .light))
    }

    @Test func blackGlyphWithColoredPartNeedsLightPlate() {
        let image = canvas { ctx in
            fill(ctx, CGRect(x: 2, y: 2, width: 8, height: 8), 0, 0, 0)
            fill(ctx, CGRect(x: 4, y: 4, width: 4, height: 4), 0.9, 0.2, 0.2)
        }
        #expect(GlyphStyle.of(image) == .colored(plate: .dark))
    }

    @Test func appIconWithMidToneRimNeedsNoPlate() {
        // Safari-like: grey outer ring + white dial + blue needle. The large white area is inside and the outline is
        // mid-tone, so no plate is needed.
        let image = canvas { ctx in
            fill(ctx, CGRect(x: 1, y: 1, width: 10, height: 10), 0.55, 0.57, 0.6)
            fill(ctx, CGRect(x: 2, y: 2, width: 8, height: 8), 1, 1, 1)
            fill(ctx, CGRect(x: 4, y: 3, width: 4, height: 6), 0.1, 0.45, 0.95)
        }
        #expect(GlyphStyle.of(image) == .colored(plate: nil))
    }

    @Test func emptyImageIsMonochrome() {
        #expect(GlyphStyle.of(canvas { _ in }) == .monochrome(.light))
    }
}

@Suite struct GlyphMaskTests {
    @Test func whiteGlyphBecomesOpaqueMaskAndBackgroundStaysClear() throws {
        let image = canvas { fill($0, CGRect(x: 2, y: 2, width: 8, height: 8), 1, 1, 1) }
        let mask = try #require(GlyphMask.make(from: image, tone: .light))
        #expect(mask.width == 12 && mask.height == 12)
        #expect(pixel(mask, 6, 6) == [255, 255, 255, 255])
        #expect(pixel(mask, 0, 0)[3] == 0)
    }

    @Test func blackGlyphBecomesOpaqueMask() throws {
        let image = canvas { fill($0, CGRect(x: 2, y: 2, width: 8, height: 8), 0, 0, 0) }
        let mask = try #require(GlyphMask.make(from: image, tone: .dark))
        #expect(pixel(mask, 6, 6)[3] == 255)
        #expect(pixel(mask, 0, 0)[3] == 0)
    }

    @Test func knockoutDetailInsideLightGlyphStaysClear() throws {
        // Black "text" in the middle of a white badge: alpha alone would smear it into a blob; with luminance
        // weighting it is knocked out.
        let image = canvas { ctx in
            fill(ctx, CGRect(x: 2, y: 2, width: 8, height: 8), 1, 1, 1)
            fill(ctx, CGRect(x: 5, y: 5, width: 2, height: 2), 0, 0, 0)
        }
        let mask = try #require(GlyphMask.make(from: image, tone: .light))
        #expect(pixel(mask, 3, 3)[3] == 255)
        #expect(pixel(mask, 5, 5)[3] == 0)
    }

    @Test func antiAliasedEdgeKeepsPartialCoverage() throws {
        let image = canvas { ctx in
            fill(ctx, CGRect(x: 2, y: 2, width: 8, height: 8), 1, 1, 1)
            // A ring of semi-transparent white edge
            fill(ctx, CGRect(x: 1, y: 1, width: 10, height: 1), 1, 1, 1, 0.5)
        }
        let mask = try #require(GlyphMask.make(from: image, tone: .light))
        let edge = [pixel(mask, 5, 1)[3], pixel(mask, 5, 10)[3]].max()!
        #expect(edge > 110 && edge < 145)
    }

    @Test func greyGlyphIsNormalisedToFullStrength() throws {
        // Glyphs on a light menu bar are often dark grey rather than pure black: normalized to full strength.
        let image = canvas { fill($0, CGRect(x: 2, y: 2, width: 8, height: 8), 0.2, 0.2, 0.2) }
        let mask = try #require(GlyphMask.make(from: image, tone: .dark))
        #expect(pixel(mask, 6, 6)[3] == 255)
    }
}
