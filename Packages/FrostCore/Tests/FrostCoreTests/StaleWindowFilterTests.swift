import Testing
import CoreGraphics
@testable import FrostCore

@Suite struct StaleWindowFilterTests {
    func item(_ id: CGWindowID, x: CGFloat = -3487, w: CGFloat, onScreen: Bool, owner: String?) -> MenuBarItem {
        MenuBarItem(windowID: id, frame: CGRect(x: x, y: 0, width: w, height: 39), isOnScreen: onScreen,
                    windowTitle: "Item-0", bundleID: owner, pid: owner == nil ? nil : 42, axDescription: nil)
    }

    @Test func dropsUnownedOffscreenZeroWidthWindows() {
        // Spike: after an app quits, its status bar window may linger in CGWindowList (width 0, off screen, not in AX).
        #expect(StaleWindowFilter.isStale(item(1, w: 0, onScreen: false, owner: nil)))
    }

    @Test func keepsWindowsFailingAnyCondition() {
        // A pushed-out item: off screen, possibly without ownership for now, but with a normal width.
        #expect(!StaleWindowFilter.isStale(item(1, w: 29, onScreen: false, owner: nil)))
        // A zero-width window with ownership (live process).
        #expect(!StaleWindowFilter.isStale(item(2, w: 0, onScreen: false, owner: "com.example")))
        // A zero-width window on screen.
        #expect(!StaleWindowFilter.isStale(item(3, x: 1500, w: 0, onScreen: true, owner: nil)))
    }

    @Test func candidatesDoNotTriggerOwnershipReads() {
        let windows = [RawStatusWindow(windowID: 1, frame: CGRect(x: -10, y: 0, width: 0, height: 39), title: "",
                                       isOnScreen: false),
                       RawStatusWindow(windowID: 2, frame: CGRect(x: -3487, y: 0, width: 29, height: 39), title: "",
                                       isOnScreen: false)]
        #expect(windows.filter(StaleWindowFilter.isCandidate).map(\.windowID) == [1])
    }

    @Test func prunesOwnershipOfExitedProcesses() {
        let cache: [CGWindowID: AXItemInfo] = [
            1: AXItemInfo(bundleID: "a", pid: 10, frame: .zero, description: nil),
            2: AXItemInfo(bundleID: "b", pid: 20, frame: .zero, description: nil),
        ]
        let pruned = StaleWindowFilter.ownershipOfLiveProcesses(cache, isAlive: { $0 == 10 })
        #expect(Set(pruned.keys) == [1])
    }
}
