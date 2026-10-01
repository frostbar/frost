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
