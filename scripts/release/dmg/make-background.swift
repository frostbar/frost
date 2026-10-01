// Generates the DMG window background (drawn offscreen; no window is shown):
//   swift scripts/release/dmg/make-background.swift scripts/release/dmg
// Writes background.png (660x400) and background@2x.png (1320x800); dmgbuild combines them into a HiDPI TIFF.
// The background is a mid-brightness blue: Finder draws icon labels in black in Light Mode and in white in
// Dark Mode, and both stay legible at this brightness.
import AppKit

let size = NSSize(width: 660, height: 400)
let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
// Icon centers in Finder coordinates (top-left origin); must match icon_locations in dmg-settings.py.
let appCenter = CGPoint(x: 165, y: 190)
let applicationsCenter = CGPoint(x: 495, y: 190)

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                               pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }
    let bounds = NSRect(origin: .zero, size: size)
    // AppKit coordinates have a bottom-left origin: flip Finder's y.
    func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: size.height - p.y) }

    // Base: a cool diagonal gradient plus a soft glow at the top.
    NSGradient(colors: [NSColor(srgbRed: 0.27, green: 0.42, blue: 0.62, alpha: 1),
                        NSColor(srgbRed: 0.40, green: 0.56, blue: 0.75, alpha: 1)])!
        .draw(in: bounds, angle: -60)
    NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)])!
        .draw(fromCenter: NSPoint(x: size.width / 2, y: size.height + 40), radius: 0,
              toCenter: NSPoint(x: size.width / 2, y: size.height + 40), radius: 380, options: [])

    // Scattered faint snowflakes.
    let flakes: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (40, 40, 34, 0.10), (600, 60, 46, 0.08), (320, 34, 22, 0.10), (560, 330, 30, 0.07),
        (90, 340, 26, 0.08), (250, 300, 16, 0.10), (420, 70, 18, 0.09), (630, 220, 20, 0.07),
    ]
    for (x, y, pt, alpha) in flakes {
        let config = NSImage.SymbolConfiguration(pointSize: pt, weight: .light)
        guard let symbol = NSImage(systemSymbolName: "snowflake", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { continue }
        // Symbol images are templates: draw the shape first, then fill it white with sourceAtop.
        let flake = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let p = flip(CGPoint(x: x, y: y))
        flake.draw(in: NSRect(x: p.x - flake.size.width / 2, y: p.y - flake.size.height / 2,
                              width: flake.size.width, height: flake.size.height),
                   from: .zero, operation: .sourceOver, fraction: alpha * 1.6)
    }

    // Arrow between the two icons.
    let from = flip(CGPoint(x: appCenter.x + 92, y: appCenter.y))
    let to = flip(CGPoint(x: applicationsCenter.x - 92, y: applicationsCenter.y))
    let arrow = NSBezierPath()
    arrow.move(to: from)
    arrow.line(to: NSPoint(x: to.x - 6, y: to.y))
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    NSColor(white: 1, alpha: 0.85).setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: to.x + 4, y: to.y))
    head.line(to: NSPoint(x: to.x - 14, y: to.y + 13))
    head.line(to: NSPoint(x: to.x - 14, y: to.y - 13))
    head.close()
    NSColor(white: 1, alpha: 0.85).setFill()
    head.fill()

    // Caption at the bottom.
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.25)
    shadow.shadowOffset = NSSize(width: 0, height: -1)
    shadow.shadowBlurRadius = 3
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    func line(_ text: String, y: CGFloat, font: NSFont, alpha: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor(white: 1, alpha: alpha), .paragraphStyle: paragraph, .shadow: shadow,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let height = string.size().height
        string.draw(in: NSRect(x: 0, y: size.height - y - height / 2, width: size.width, height: height))
    }
    line("Drag Frost to Applications to install", y: 340, font: .systemFont(ofSize: 15, weight: .semibold), alpha: 0.95)

    return rep.representation(using: .png, properties: [:])!
}

try render(scale: 1).write(to: outDir.appendingPathComponent("background.png"))
try render(scale: 2).write(to: outDir.appendingPathComponent("background@2x.png"))
print("wrote \(outDir.path)/background.png and background@2x.png")
