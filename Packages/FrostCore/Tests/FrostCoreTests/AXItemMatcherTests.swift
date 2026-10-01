import Testing
import CoreGraphics
@testable import FrostCore

@Suite struct AXItemMatcherTests {
    func win(_ id: CGWindowID, x: CGFloat, w: CGFloat, title: String = "Item-0",
             onScreen: Bool = true) -> RawStatusWindow {
        RawStatusWindow(windowID: id, frame: CGRect(x: x, y: 0, width: w, height: 39), title: title,
                        isOnScreen: onScreen)
    }
    func ax(_ bundle: String, x: CGFloat, w: CGFloat, pid: pid_t = 1) -> AXItemInfo {
        AXItemInfo(bundleID: bundle, pid: pid, frame: CGRect(x: x, y: 0, width: w, height: 24), description: nil)
    }

    @Test func matchesByMidXWithinTolerance() {
        // Measured: window x=1139 w=31 (mid 1154.5), AX x=1138 w=33 (mid 1154.5)
        let r = AXItemMatcher.merge(windows: [win(1, x: 1139, w: 31)], axItems: [ax("com.example.status-item", x: 1138, w: 33)])
        #expect(r[0].bundleID == "com.example.status-item")
        #expect(r[0].pid == 1)
    }

    @Test func leavesUnmatchedWindowsWithNilBundle() {
        let r = AXItemMatcher.merge(windows: [win(1, x: 100, w: 30)], axItems: [ax("a", x: 400, w: 30)])
        #expect(r[0].bundleID == nil)
    }

    @Test func eachAXItemMatchesAtMostOnce() {
        let r = AXItemMatcher.merge(windows: [win(1, x: 100, w: 30), win(2, x: 101, w: 30)],
                                    axItems: [ax("a", x: 100, w: 30)])
        #expect(r.compactMap(\.bundleID) == ["a"])
    }

    @Test func picksClosestCandidate() {
        let r = AXItemMatcher.merge(windows: [win(1, x: 100, w: 30)],
                                    axItems: [ax("far", x: 103, w: 30), ax("near", x: 101, w: 30)])
        #expect(r[0].bundleID == "near")
    }

    @Test func ignoresZeroSizedAXItems() {
        let r = AXItemMatcher.merge(windows: [win(1, x: 0, w: 0)], axItems: [ax("cc", x: 0, w: 0)])
        #expect(r[0].bundleID == nil)
    }

    @Test func bestMatchRejectsDistantZeroSizedAndMissing() {
        let target = CGRect(x: 100, y: 0, width: 30, height: 24)
        #expect(AXItemMatcher.bestMatch(for: target, among: []) == nil)
        #expect(AXItemMatcher.bestMatch(for: target, among: [CGRect(x: 200, y: 0, width: 30, height: 24)]) == nil)
        #expect(AXItemMatcher.bestMatch(for: target, among: [CGRect(x: 100, y: 0, width: 0, height: 0)]) == nil)
        #expect(AXItemMatcher.bestMatch(for: target, among: [
            CGRect(x: 103, y: 0, width: 30, height: 24), CGRect(x: 101, y: 0, width: 30, height: 24),
        ]) == 1)
    }

    @Test func preservesWindowOrderAndFields() {
        let r = AXItemMatcher.merge(windows: [win(5, x: 10, w: 30, title: "Clock")], axItems: [])
        #expect(r.map(\.windowID) == [5])
        #expect(r[0].windowTitle == "Clock")
    }

    @Test func carriesOnScreenFlag() {
        let r = AXItemMatcher.merge(windows: [win(1, x: -3487, w: 29, onScreen: false), win(2, x: 1558, w: 29)],
                                    axItems: [])
        #expect(r.map(\.isOnScreen) == [false, true])
    }

    // MARK: - Windows moving during the async read (consensusOwnership)

    @Test func consensusKeepsOwnershipWhenNothingMoved() {
        let windows = [win(1, x: 100, w: 30), win(2, x: 130, w: 30)]
        let r = AXItemMatcher.consensusOwnership(before: windows, after: windows,
                                                 axItems: [ax("a", x: 99, w: 32), ax("b", x: 129, w: 32, pid: 2)])
        #expect(r[1]?.bundleID == "a")
        #expect(r[2]?.bundleID == "b")
        #expect(r[2]?.pid == 2)
    }

    @Test func consensusToleratesSmallDrift() {
        // An icon on the left changed width and shifted the rest by 2 pt: both snapshots match the same AX item.
        let r = AXItemMatcher.consensusOwnership(before: [win(1, x: 100, w: 30)], after: [win(1, x: 102, w: 30)],
                                                 axItems: [ax("a", x: 100, w: 32)])
        #expect(r[1]?.bundleID == "a")
    }

    @Test func consensusDropsWindowsThatMovedDuringTheRead() {
        // During the read, 1 was moved to the right of 2: AX may have read either state, and the two snapshots'
        // matches disagree → not accepted (retried later).
        let before = [win(1, x: 100, w: 30), win(2, x: 130, w: 30)]
        let after = [win(2, x: 100, w: 30), win(1, x: 130, w: 30)]
        let r = AXItemMatcher.consensusOwnership(before: before, after: after,
                                                 axItems: [ax("a", x: 99, w: 32), ax("b", x: 129, w: 32)])
        #expect(r.isEmpty)
    }

    @Test func consensusIgnoresWindowsMissingFromEitherSnapshot() {
        let r = AXItemMatcher.consensusOwnership(before: [win(1, x: 100, w: 30)],
                                                 after: [win(1, x: 100, w: 30), win(2, x: 130, w: 30)],
                                                 axItems: [ax("a", x: 99, w: 32), ax("b", x: 129, w: 32)])
        #expect(Set(r.keys) == [1])
    }
}
