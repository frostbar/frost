import Testing
import CoreGraphics
@testable import FrostCore

@Suite struct TileWidthTests {
    @Test func captureWidthWins() {
        #expect(TileWidth.width(captureWidth: 87.2, frameWidth: 60, standard: 40, cap: 216) == 88)
    }

    @Test func narrowItemsGetAStandardTile() {
        #expect(TileWidth.width(captureWidth: 24, frameWidth: 24, standard: 40, cap: 216) == 40)
        #expect(TileWidth.width(captureWidth: nil, frameWidth: 24, standard: 40, cap: 216) == 40)
    }

    /// No capture yet (first launch, or the cached one no longer matches): the tile already has the width the capture
    /// will have (the item's frame), so the panel doesn't resize when the capture arrives.
    @Test func withoutACaptureTheTileReservesTheItemsWidth() {
        let placeholder = TileWidth.width(captureWidth: nil, frameWidth: 96.5, standard: 40, cap: 216)
        let captured = TileWidth.width(captureWidth: 96.5, frameWidth: 96.5, standard: 40, cap: 216)
        #expect(placeholder == 97)
        #expect(placeholder == captured)
    }

    @Test func neverWiderThanTheGrid() {
        #expect(TileWidth.width(captureWidth: 400, frameWidth: 400, standard: 40, cap: 216) == 216)
        #expect(TileWidth.width(captureWidth: nil, frameWidth: 400, standard: 40, cap: 216) == 216)
    }
}
