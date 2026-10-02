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

@Suite struct TileWidthMemoryTests {
    /// A static item keeps its exact width (no rounding while it never changes).
    @Test func staticWidthsAreExact() {
        var memory = TileWidthMemory()
        #expect(memory.hold(1, width: 53.2) == 53.2)
        #expect(memory.hold(1, width: 53.2) == 53.2)
    }

    /// A dynamic-width item (network speed text): narrower readings keep the widest width seen this session, so the
    /// tile never shrinks back and the panel never oscillates.
    @Test func narrowerWidthsKeepTheWidest() {
        var memory = TileWidthMemory()
        _ = memory.hold(1, width: 48)
        let widened = memory.hold(1, width: 61)
        #expect(widened >= 61)
        #expect(memory.hold(1, width: 40) == widened)
        #expect(memory.hold(1, width: 48) == widened)
    }

    /// Once an item's width has changed, growth is rounded up to a step so small increases don't reflow again.
    @Test func changingWidthsRoundUpToAStep() {
        var memory = TileWidthMemory()
        _ = memory.hold(1, width: 48)
        let first = memory.hold(1, width: 49.5)
        #expect(first == 56)
        #expect(memory.hold(1, width: 55) == 56)
        #expect(memory.hold(1, width: 57) == 64)
    }

    @Test func itemsAreIndependentAndResetForgets() {
        var memory = TileWidthMemory()
        _ = memory.hold(1, width: 80)
        #expect(memory.hold(2, width: 30) == 30)
        memory.reset()
        #expect(memory.hold(1, width: 50) == 50)
    }

    /// Over a session of fluctuating readings, the held width changes only a handful of times (each change is at
    /// most one reflow).
    @Test func fluctuatingReadingsSettleQuickly() {
        var memory = TileWidthMemory()
        let readings: [CGFloat] = [40, 52, 46, 61, 40, 58, 61, 44, 52, 61, 40, 48]
        var changes = 0
        var previous: CGFloat?
        for reading in readings {
            let held = memory.hold(7, width: reading)
            if let previous, previous != held { changes += 1 }
            previous = held
        }
        #expect(changes <= 2)
    }
}
