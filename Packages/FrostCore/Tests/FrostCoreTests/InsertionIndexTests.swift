import Testing
import CoreGraphics
@testable import FrostCore

@Suite struct InsertionIndexTests {
    // midX of three tiles [A, B, C]
    let mids: [CGFloat] = [20, 60, 100]

    @Test func dropBeforeFirst() { #expect(InsertionIndex.compute(dropX: 5, tileMidXs: mids, draggedIndex: nil) == 0) }
    @Test func dropBetween() { #expect(InsertionIndex.compute(dropX: 70, tileMidXs: mids, draggedIndex: nil) == 2) }
    @Test func dropAfterLast() { #expect(InsertionIndex.compute(dropX: 500, tileMidXs: mids, draggedIndex: nil) == 3) }
    @Test func emptyRow() { #expect(InsertionIndex.compute(dropX: 10, tileMidXs: [], draggedIndex: nil) == 0) }

    @Test func draggingAToJustBeforeCYieldsPostRemovalIndex1() {
        // In [A,B,C], drag A to just before C: with A removed the list is [B,C], so before C = 1
        #expect(InsertionIndex.compute(dropX: 90, tileMidXs: mids, draggedIndex: 0) == 1)
    }

    @Test func draggingCToFrontYields0() {
        #expect(InsertionIndex.compute(dropX: 5, tileMidXs: mids, draggedIndex: 2) == 0)
    }

    @Test func droppingOntoOwnPositionYieldsOwnIndex() {
        // Drop B near its original spot → index 1 with B removed (DropResolver treats it as not moved)
        #expect(InsertionIndex.compute(dropX: 62, tileMidXs: mids, draggedIndex: 1) == 1)
    }
}
