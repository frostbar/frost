import Testing
import CoreGraphics
@testable import FrostCore

@Suite struct FrostControlLocatorTests {
    func item(_ id: CGWindowID, x: CGFloat, w: CGFloat, title: String = "") -> MenuBarItem {
        MenuBarItem(windowID: id, frame: CGRect(x: x, y: 0, width: w, height: 39), isOnScreen: x >= 0,
                    windowTitle: title, bundleID: "dev.frost.Frost", pid: 1, axDescription: nil)
    }

    // Measured collapsed layout: [AH −8503 w5016][X][H −3458 w5016][Icon 1558 w29][V 1587]
    var items: [MenuBarItem] {
        [item(10, x: -8503, w: 5016, title: "FrostAlwaysHiddenSeparator"),
         item(11, x: -3487, w: 29, title: "Other"),
         item(12, x: -3458, w: 5016, title: "FrostHiddenSeparator"),
         item(13, x: 1558, w: 29, title: "FrostIcon"),
         item(14, x: 1587, w: 29, title: "Item-0")]
    }

    @Test func locatesByFrame() {
        // Matches by frame even with empty titles (no Screen Recording permission); a ±1 pt error is within tolerance.
        let untitled = items.map { item($0.windowID, x: $0.frame.minX, w: $0.frame.width) }
        let r = FrostControlLocator.locate(in: untitled,
                                           iconFrame: CGRect(x: 1559, y: 0, width: 28, height: 39),
                                           hiddenFrame: CGRect(x: -3458, y: 0, width: 5016, height: 39),
                                           alwaysHiddenFrame: CGRect(x: -8503, y: 0, width: 5016, height: 39))
        #expect(r == FrostControlWindows(icon: 13, hiddenSeparator: 12, alwaysHiddenSeparator: 10))
    }

    @Test func frameMatchRequiresSimilarWidth() {
        // Same midX but width off by > 2 is not a match (e.g. a separator whose length is changing) → falls back to the title.
        let untitled = items.map { item($0.windowID, x: $0.frame.minX, w: $0.frame.width) }
        let r = FrostControlLocator.locate(in: untitled,
                                           iconFrame: CGRect(x: 1552, y: 0, width: 41, height: 39),
                                           hiddenFrame: CGRect(x: -3458, y: 0, width: 5016, height: 39),
                                           alwaysHiddenFrame: CGRect(x: -8503, y: 0, width: 5016, height: 39))
        #expect(r == nil)
    }

    @Test func fallsBackToTitleWhenFrameMisses() {
        let r = FrostControlLocator.locate(in: items,
                                           iconFrame: CGRect(x: 400, y: 0, width: 29, height: 39),
                                           hiddenFrame: nil,
                                           alwaysHiddenFrame: CGRect(x: -8503, y: 0, width: 5016, height: 39))
        #expect(r == FrostControlWindows(icon: 13, hiddenSeparator: 12, alwaysHiddenSeparator: 10))
    }

    @Test func returnsNilWhenAnyControlIsMissing() {
        let withoutIcon = items.filter { $0.windowID != 13 }
        let r = FrostControlLocator.locate(in: withoutIcon, iconFrame: nil, hiddenFrame: nil, alwaysHiddenFrame: nil)
        #expect(r == nil)
    }

    func item(_ id: CGWindowID, x: CGFloat, w: CGFloat, title: String = "", onScreen: Bool) -> MenuBarItem {
        MenuBarItem(windowID: id, frame: CGRect(x: x, y: 0, width: w, height: 39), isOnScreen: onScreen,
                    windowTitle: title, bundleID: "dev.frost.Frost", pid: 1, axDescription: nil)
    }

    @Test func prefersOnScreenThenNewestAmongFrameMatches() {
        // After a relaunch, a leftover window of the previous instance may have the same frame as the new one.
        let stale = item(5, x: 1558, w: 29, title: "FrostIcon", onScreen: false)
        let live = item(40, x: 1558, w: 29, title: "FrostIcon", onScreen: true)
        let frame = CGRect(x: 1558, y: 0, width: 29, height: 39)
        #expect(FrostControlLocator.find(in: [live, stale], frame: frame, title: "FrostIcon") == 40)
        #expect(FrostControlLocator.find(in: [stale, live], frame: frame, title: "FrostIcon") == 40)
        // Both off screen (pushed-out separators): take the larger windowID (the newer window).
        let oldSeparator = item(6, x: -3458, w: 5016, title: "FrostHiddenSeparator", onScreen: false)
        let newSeparator = item(41, x: -3458, w: 5016, title: "FrostHiddenSeparator", onScreen: false)
        #expect(FrostControlLocator.find(in: [newSeparator, oldSeparator],
                                         frame: CGRect(x: -3458, y: 0, width: 5016, height: 39),
                                         title: "FrostHiddenSeparator") == 41)
    }

    @Test func prefersOnScreenThenNewestAmongTitleMatches() {
        let a = item(5, x: 1558, w: 29, title: "FrostIcon", onScreen: false)
        let b = item(9, x: 1500, w: 29, title: "FrostIcon", onScreen: true)
        let c = item(7, x: 1400, w: 29, title: "FrostIcon", onScreen: true)
        #expect(FrostControlLocator.find(in: [a, c, b], frame: nil, title: "FrostIcon") == 9)
        #expect(FrostControlLocator.find(in: [a], frame: nil, title: "FrostIcon") == 5)
    }

    @Test func returnsNilWithoutFramesOrTitles() {
        let untitled = items.map { item($0.windowID, x: $0.frame.minX, w: $0.frame.width) }
        #expect(FrostControlLocator.locate(in: untitled, iconFrame: nil, hiddenFrame: nil,
                                           alwaysHiddenFrame: nil) == nil)
    }
}
