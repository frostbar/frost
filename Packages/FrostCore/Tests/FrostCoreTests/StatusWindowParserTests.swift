import Testing
import CoreGraphics
@testable import FrostCore

@Suite struct StatusWindowParserTests {
    func info(layer: Int, id: Int, x: Int, w: Int, title: String?, onscreen: Bool?) -> [String: Any] {
        var d: [String: Any] = [
            kCGWindowLayer as String: layer,
            kCGWindowNumber as String: id,
            kCGWindowBounds as String: ["X": x, "Y": 0, "Width": w, "Height": 39],
        ]
        if let title { d[kCGWindowName as String] = title }
        if let onscreen { d[kCGWindowIsOnscreen as String] = onscreen }
        return d
    }

    @Test func keepsOnlyStatusLayerWindows() {
        let result = StatusWindowParser.parse([
            info(layer: 25, id: 10, x: 100, w: 30, title: "A", onscreen: true),
            info(layer: 0, id: 11, x: 100, w: 30, title: "Doc", onscreen: true),
            info(layer: 24, id: 12, x: 0, w: 1800, title: "Menubar", onscreen: true),
        ])
        #expect(result.map(\.windowID) == [10])
    }

    @Test func parsesFrameTitleAndOnscreen() {
        let w = StatusWindowParser.parse([info(layer: 25, id: 7, x: 943, w: 38, title: "Item-0", onscreen: nil)])[0]
        #expect(w.frame == CGRect(x: 943, y: 0, width: 38, height: 39))
        #expect(w.title == "Item-0")
        #expect(w.isOnScreen == false)
    }

    @Test func missingTitleBecomesEmptyString() {
        let w = StatusWindowParser.parse([info(layer: 25, id: 7, x: 0, w: 38, title: nil, onscreen: true)])[0]
        #expect(w.title == "")
    }

    @Test func dropsEntriesWithoutBounds() {
        var bad = info(layer: 25, id: 9, x: 0, w: 1, title: "A", onscreen: true)
        bad[kCGWindowBounds as String] = nil
        #expect(StatusWindowParser.parse([bad]).isEmpty)
    }

    @Test func queryingNoWindowsReadsNothing() {
        #expect(StatusWindowParser.windows(withIDs: [CGWindowID]()).isEmpty)
        // Window ID 0 never exists.
        #expect(StatusWindowParser.windows(withIDs: [CGWindowID(0)]).isEmpty)
    }
}
