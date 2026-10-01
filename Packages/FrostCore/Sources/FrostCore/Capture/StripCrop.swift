import CoreGraphics

/// Geometry for capturing one menu bar strip and then cropping each item's capture by its frame (pure logic).
///
/// The strip capture uses a display filter that includes only these items' windows
/// (`SCContentFilter(display:including:)`) with a transparent background: measured on a VM, the cropped images are
/// pixel-identical (alpha included) to per-window captures (`desktopIndependentWindow`), but need only one capture
/// (about 30 ms, versus about 19 ms × the number of items for per-window captures).
public enum StripCrop {
    /// The strip covering `frames` (global coordinates, points): display-local coordinates (points, top-left origin),
    /// rounded out to whole points and clamped to the display. Returns nil when no frame intersects the display.
    public static func stripRect(covering frames: [CGRect], display: CGRect) -> CGRect? {
        let visible = frames.map { $0.intersection(display) }.filter { !$0.isNull && !$0.isEmpty }
        guard let first = visible.first else { return nil }
        let union = visible.dropFirst().reduce(first) { $0.union($1) }
        let local = union.offsetBy(dx: -display.minX, dy: -display.minY)
        return CGRect(x: local.minX.rounded(.down), y: local.minY.rounded(.down),
                      width: local.maxX.rounded(.up) - local.minX.rounded(.down),
                      height: local.maxY.rounded(.up) - local.minY.rounded(.down))
    }

    /// An item's pixel rectangle within the strip capture. `stripOrigin`: global coordinates (points) of the strip's
    /// top-left corner; `imageSize`: the strip capture's pixel size. Matches the per-window capture size
    /// (`Int(frame.width × scale)`). Returns nil when the item doesn't lie entirely inside the capture (fall back to a
    /// per-window capture).
    public static func pixelRect(of itemFrame: CGRect, stripOrigin: CGPoint, scale: CGFloat,
                                 imageSize: CGSize) -> CGRect? {
        let x = ((itemFrame.minX - stripOrigin.x) * scale).rounded()
        let y = ((itemFrame.minY - stripOrigin.y) * scale).rounded()
        let width = (itemFrame.width * scale).rounded(.down)
        let height = (itemFrame.height * scale).rounded(.down)
        guard width >= 1, height >= 1, x >= 0, y >= 0,
              x + width <= imageSize.width, y + height <= imageSize.height else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
