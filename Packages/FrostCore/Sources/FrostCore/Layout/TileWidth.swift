import CoreGraphics

/// Width of an icon tile in the Frost Bar grid.
///
/// A tile is as wide as the item's capture (`captureWidth`, at least one standard tile, at most the grid width). An
/// item without a capture yet (first launch with an empty disk cache, or a cached capture that no longer matches the
/// item's size) shows its app icon in a tile that already reserves the width its capture will have (the item's frame):
/// when the live refresh delivers the capture, the panel neither resizes nor reflows. The width only changes when
/// the capture width does, so swapping captures never makes the panel jump.
public enum TileWidth {
    public static func width(captureWidth: CGFloat?, frameWidth: CGFloat, standard: CGFloat, cap: CGFloat) -> CGFloat {
        min(max(standard, (captureWidth ?? frameWidth).rounded(.up)), cap)
    }
}

/// Hysteresis for tile widths while the Frost Bar is open: each item's tile keeps the widest width seen during the
/// session, so an item whose width keeps changing (network speed, timers) never makes the panel shrink and grow again,
/// or a tile move back and forth between rows.
///
/// An item whose width never changes keeps its exact width. Once an item's width has changed, its held width is
/// rounded up to a multiple of `step`: small increases then fit in the room already reserved, so the grid reflows at
/// most a few times per item and session (in practice once, within the first seconds). The capture is drawn at its own
/// size, centered in the (possibly wider) tile.
public struct TileWidthMemory: Sendable, Equatable {
    public static let step: CGFloat = 8

    private var widest: [UInt32: CGFloat] = [:]

    public init() {}

    /// The width to lay `id` out with, given its current width (capture or frame width); remembers it.
    public mutating func hold(_ id: UInt32, width: CGFloat) -> CGFloat {
        guard let previous = widest[id] else {
            widest[id] = width
            return width
        }
        if width == previous { return previous }
        guard width > previous else { return previous }
        let held = (width / Self.step).rounded(.up) * Self.step
        widest[id] = held
        return held
    }

    /// Starts a new session (the panel opened).
    public mutating func reset() {
        widest.removeAll()
    }
}
