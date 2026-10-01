import CoreGraphics

/// Captures are white or black glyphs on a transparent background; the tile background must be chosen dark or light
/// accordingly, or the glyph would be invisible.
/// Tile background: `.light` glyph → `Color.black.opacity(0.55)`; `.dark` glyph → `Color.white.opacity(0.7)`.
public enum GlyphTone: String, Sendable, Codable {
    case light, dark

    /// Average luminance of pixels with alpha > 0.5; > 0.5 is light. Returns light when there are no opaque pixels.
    public static func of(_ image: CGImage) -> GlyphTone {
        GlyphPixels(image)?.tone ?? .light
    }
}

/// How a capture should be displayed on glass that adapts its brightness to the background.
///
/// macOS 26 glass gets lighter / darker following the content behind it, so a white (or black) glyph captured for the
/// menu bar appearance may land on glass of the same color. Monochrome glyphs (the vast majority of menu bar icons)
/// become template images (`GlyphMask`) re-tinted with the foreground color, always following the glass's actual
/// brightness. Colored icons are shown as is, and need a backing plate only when their outline is pure white / pure
/// black (e.g. a white battery outline + green charge level): such an outline would vanish on glass of the same
/// color. Icons whose outline is itself colored or mid-tone (e.g. app icons) don't need one.
public enum GlyphStyle: Sendable, Equatable, Codable {
    /// Monochrome glyph: displayed as the template image produced by `GlyphMask.make(from:tone:)`.
    case monochrome(GlyphTone)
    /// Colored icon: displayed as is. A non-nil `plate` means the icon's outline is a neutral color of that tone and
    /// needs the matching plate.
    case colored(plate: GlyphTone?)

    /// Opaque pixels whose chroma (max − min after un-premultiplying) exceeds this count as "colored".
    /// Anti-aliasing at capture edges and the slight tint from the menu bar's frosted material are far below it.
    static let chromaThreshold = 0.25
    /// An icon counts as colored when colored pixels exceed this fraction of opaque pixels (a few stray colored
    /// pixels below it are treated as monochrome).
    static let coloredFraction = 0.04
    /// A colored icon needs a plate when near-pure-white (near-pure-black) neutral pixels reach this fraction of its
    /// outline pixels.
    static let plateEdgeFraction = 0.6

    public static func of(_ image: CGImage) -> GlyphStyle {
        guard let pixels = GlyphPixels(image), pixels.opaque > 0 else { return .monochrome(.light) }
        let opaque = Double(pixels.opaque)
        guard Double(pixels.colored) > coloredFraction * opaque else { return .monochrome(pixels.tone) }
        let edge = Double(max(pixels.edge, 1))
        if Double(pixels.edgeWhite) >= plateEdgeFraction * edge { return .colored(plate: .light) }
        if Double(pixels.edgeBlack) >= plateEdgeFraction * edge { return .colored(plate: .dark) }
        return .colored(plate: nil)
    }
}

/// Turns a monochrome glyph capture into a template image (a white image where only alpha matters), for SwiftUI's
/// `.renderingMode(.template)` to tint with the foreground color.
///
/// Alpha can't be copied directly: some glyphs are two-tone opaque shapes like "black text on white" (e.g. a rounded
/// badge with a number), which would smear into a solid blob using alpha alone. So coverage is weighted by luminance:
/// `.light` glyphs are more opaque the brighter they are, `.dark` glyphs the darker they are; then it is normalized
/// by the brightest (darkest) pixel so grey-toned glyphs also get the full foreground color. Alpha at anti-aliased
/// edges is preserved.
public enum GlyphMask {
    public static func make(from image: CGImage, tone: GlyphTone) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, var pixels = GlyphPixels.rgba(image) else { return nil }
        // Un-premultiplied luminance 0…1; the normalization reference is the brightest (light) / darkest (dark)
        // luminance among opaque pixels.
        func luminance(_ i: Int) -> Double {
            let a = Double(pixels[i + 3])
            guard a > 0 else { return 0 }
            return GlyphPixels.luminance(pixels[i], pixels[i + 1], pixels[i + 2]) / a
        }
        var reference = tone == .light ? 0.0 : 1.0
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 127 {
            reference = tone == .light ? max(reference, luminance(i)) : min(reference, luminance(i))
        }
        let span = tone == .light ? reference : 1 - reference
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            let l = luminance(i)
            let coverage = tone == .light ? l : 1 - l
            let weight = span > 0.05 ? min(1, coverage / span) : 1
            let m = UInt8((a * weight * 255).rounded())
            pixels[i] = m; pixels[i + 1] = m; pixels[i + 2] = m; pixels[i + 3] = m
        }
        return pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }
}

/// Pixel statistics gathered in one pass (only pixels with alpha > 0.5 are counted; semi-transparent anti-aliased
/// edges don't take part in classification).
struct GlyphPixels {
    var opaque = 0
    var luminance = 0.0
    var colored = 0
    /// Outline pixels: opaque, with at least one of the four neighbors transparent (or outside the image).
    var edge = 0
    /// Near-pure-white / near-pure-black neutral pixels among the outline pixels.
    var edgeWhite = 0
    var edgeBlack = 0

    var tone: GlyphTone { opaque > 0 && luminance / Double(opaque) <= 0.5 ? .dark : .light }

    init?(_ image: CGImage) {
        guard let pixels = Self.rgba(image) else { return nil }
        let width = image.width, height = image.height
        func isOpaque(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < width && y < height && pixels[(y * width + x) * 4 + 3] > 127
        }
        for y in 0..<height {
            for x in 0..<width where isOpaque(x, y) {
                let i = (y * width + x) * 4
                let a = Double(pixels[i + 3])
                let r = pixels[i], g = pixels[i + 1], b = pixels[i + 2]
                // Un-premultiply
                let l = Self.luminance(r, g, b) / a
                let isColored = Double(max(r, g, b) - min(r, g, b)) / a > GlyphStyle.chromaThreshold
                opaque += 1
                luminance += l
                if isColored { colored += 1 }
                if !isOpaque(x - 1, y) || !isOpaque(x + 1, y) || !isOpaque(x, y - 1) || !isOpaque(x, y + 1) {
                    edge += 1
                    if !isColored, l > 0.8 { edgeWhite += 1 }
                    if !isColored, l < 0.2 { edgeBlack += 1 }
                }
            }
        }
    }

    /// Rec. 709 luminance (inputs are premultiplied components; the result is on the same scale as the components).
    static func luminance(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Double {
        0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
    }

    /// Draws into an RGBA8 (premultiplied alpha) buffer.
    static func rgba(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
