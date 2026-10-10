import CoreGraphics

/// Lifts one item's glyph out of a capture of the menu bar strip — the way macOS 27 has to capture icons.
///
/// On macOS 26 every status item is its own window, so a capture of that window contains the glyph on a *transparent*
/// background and can be used as it is. macOS 27 has no per-item windows (and `MenuBarAgent`'s own window is not
/// shareable: `SCShareableContent` lists none of its windows), so the only thing that can be captured is the display's
/// menu bar strip, which is **opaque**: the wallpaper shows through the bar's translucent material.
///
/// What makes the pixels usable anyway is that the bar is a *blurred* material: measured on a 1728 pt display, the
/// background inside a 32 pt wide crop varies by at most one level per channel, while the glyph deviates from it by up
/// to ~190. So the background is estimated per column (interpolating between the crop's top and bottom margins, which
/// the glyph doesn't reach) and subtracted; what is left is the glyph, with its colour, on alpha.
///
/// The result is deliberately *the same shape* as a macOS 26 per-item capture, so everything downstream — glyph tone,
/// style, mask, tile widths, the disk cache — is untouched.
public enum StripGlyphExtraction {
    /// Rows at the top and bottom of a crop used to estimate the background. The bar is 24–30 pt tall and glyphs sit
    /// in its middle, so the outermost rows are background.
    public static let backgroundMargin = 3
    /// How far a pixel must deviate from the estimated background (0–255) to count as glyph rather than noise.
    public static let deviationFloor = 10
    /// Alpha per unit of deviation above the floor: a deviation of 64 is fully opaque.
    public static let gain = 4
    /// A crop whose glyph covers less than this is treated as "nothing is drawn here".
    public static let minimumCoverage = 0.02

    /// Pixels in the capturer's canonical layout: BGRA in memory (little-endian premultiplied ARGB), tightly packed.
    public struct Buffer: Equatable, Sendable {
        public let bytes: [UInt8]
        public let width: Int
        public let height: Int

        public init(bytes: [UInt8], width: Int, height: Int) {
            self.bytes = bytes
            self.width = width
            self.height = height
        }
    }

    public struct Extracted: Equatable, Sendable {
        /// The glyph on straight alpha, in the same layout as the input.
        public let buffer: Buffer
        /// Fraction of pixels carrying glyph: the caller uses it to tell "this item is drawn here" from "the bar
        /// doesn't draw anything at this frame" (a pushed-out icon keeps reporting its old frame).
        public let coverage: Double
    }

    /// - Returns: nil when the buffer is not a usable image (empty, or shorter than its size implies).
    public static func extract(_ crop: Buffer) -> Extracted? {
        let width = crop.width, height = crop.height
        guard width > 1, height > 2 * backgroundMargin + 1, crop.bytes.count >= width * height * 4 else { return nil }
        var out = [UInt8](repeating: 0, count: width * height * 4)
        var covered = 0
        let lastRow = height - 1
        for x in 0..<width {
            let column = x * 4
            func mean(_ rows: Range<Int>) -> (Double, Double, Double) {
                var b = 0.0, g = 0.0, r = 0.0
                for y in rows {
                    let o = y * width * 4 + column
                    b += Double(crop.bytes[o]); g += Double(crop.bytes[o + 1]); r += Double(crop.bytes[o + 2])
                }
                let n = Double(rows.count)
                return (b / n, g / n, r / n)
            }
            let top = mean(0..<backgroundMargin)
            let bottom = mean((lastRow - backgroundMargin + 1)..<(lastRow + 1))
            for y in 0..<height {
                let o = y * width * 4 + column
                // The background varies from top to bottom (the bar blurs the wallpaper): interpolate between the
                // two margins rather than using one value for the whole column.
                let t = Double(y) / Double(lastRow)
                let bgB = top.0 + (bottom.0 - top.0) * t
                let bgG = top.1 + (bottom.1 - top.1) * t
                let bgR = top.2 + (bottom.2 - top.2) * t
                let b = Double(crop.bytes[o]), g = Double(crop.bytes[o + 1]), r = Double(crop.bytes[o + 2])
                let deviation = max(abs(b - bgB), abs(g - bgG), abs(r - bgR))
                guard deviation > Double(deviationFloor) else { continue }
                let alpha = UInt8(min(255, (deviation - Double(deviationFloor)) * Double(gain)))
                let factor = Double(alpha) / 255
                out[o] = UInt8(min(255, b * factor))
                out[o + 1] = UInt8(min(255, g * factor))
                out[o + 2] = UInt8(min(255, r * factor))
                out[o + 3] = alpha
                covered += 1
            }
        }
        let total = width * height
        return Extracted(buffer: Buffer(bytes: out, width: width, height: height),
                         coverage: Double(covered) / Double(total))
    }

    /// Whether the crop carries an item at all. A frame the bar doesn't draw (a pushed-out icon keeps its old frame)
    /// crops to background only; reporting no image for it is honest, and the item falls back to its app icon.
    public static func isItemDrawn(_ extracted: Extracted) -> Bool {
        extracted.coverage >= minimumCoverage
    }
}

public extension StripGlyphExtraction.Buffer {
    /// The buffer as a capture image, in the capturer's canonical layout
    /// (`premultipliedFirst | byteOrder32Little`, 8 bits per component), which is what every capture — and the
    /// extraction's own output — is in.
    func cgImage() -> CGImage? {
        guard width > 0, height > 0, bytes.count >= width * height * 4 else { return nil }
        var pixels = bytes
        return pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return nil }
            return context.makeImage()
        }
    }
}
