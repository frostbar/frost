import Testing
import AppKit
@testable import FrostCore

@Suite struct ItemClickerTests {
    typealias W = ItemClicker.WindowInfo
    let app: pid_t = 500

    @Test func pressDispositionFollowsSpikeFindings() {
        // AXPress on an NSMenu item blocks and then returns cannotComplete, but the menu is already open →
        // treat as delivered; no extra click.
        #expect(ItemClicker.pressDisposition(.success) == .delivered)
        #expect(ItemClicker.pressDisposition(.cannotComplete) == .delivered)
        for e: AXError in [.actionUnsupported, .attributeUnsupported, .noValue, .invalidUIElement, .failure] {
            #expect(ItemClicker.pressDisposition(e) == .fallBackToEvent)
        }
        for e: AXError in [.apiDisabled, .illegalArgument, .notImplemented] {
            #expect(ItemClicker.pressDisposition(e) == .failed)
        }
    }

    @Test func appleSystemItemsAreClickedWithAnEventNotAXPress() {
        // Measured in a VM: Spotlight's status item returns .success for AXPress but does nothing (a real click
        // opens Spotlight).
        // Other system items can't all be verified: every com.apple.* item uses a HID click directly.
        for id in ["com.apple.Spotlight", "com.apple.controlcenter", "com.apple.TextInputMenuAgent",
                   "com.apple.systemuiserver"] {
            #expect(!ItemClicker.acceptsAXPress(bundleID: id), "\(id)")
        }
        #expect(ItemClicker.acceptsAXPress(bundleID: "dev.frost.FakeItems"))
        // Prefix only: third-party apps with "apple" in the name, and "com.apple" without the dot, don't count.
        #expect(ItemClicker.acceptsAXPress(bundleID: "com.applecorp.Tool"))
        #expect(ItemClicker.acceptsAXPress(bundleID: "org.example.apple"))
        #expect(ItemClicker.acceptsAXPress(bundleID: "com.apple"))
        #expect(ItemClicker.acceptsAXPress(bundleID: nil))
    }

    @Test func parsesWindowInfoDictionaries() {
        let list: [[String: Any]] = [
            [kCGWindowNumber as String: 42, kCGWindowLayer as String: 101, kCGWindowOwnerPID as String: 500],
            [kCGWindowNumber as String: 43],
            [kCGWindowLayer as String: 0], // no window number → dropped
        ]
        #expect(ItemClicker.windowInfos(from: list) == [
            W(windowID: 42, layer: 101, ownerPID: 500), W(windowID: 43, layer: 0, ownerPID: nil),
        ])
    }

    @Test func detectsMenusFromAnyOwnerAndItemAppWindowsIncludingPopovers() {
        let windows = [
            W(windowID: 1, layer: 101, ownerPID: 777), // NSMenu (layer 101)
            W(windowID: 2, layer: 25, ownerPID: app),  // NSPopover (layer 25, owned by the app)
            W(windowID: 3, layer: 3, ownerPID: app),   // the app's own panel
        ]
        #expect(ItemClicker.presentationWindowIDs(in: windows, baseline: [], statusWindows: [],
                                                  ownerPID: app) == [1, 2, 3])
    }

    @Test func ignoresObservedNoiseWindows() {
        // Measured in the spike: unrelated new windows that appeared within 3 s of a click.
        let noise = [
            W(windowID: 10, layer: 21, ownerPID: 11),         // Notification Center (full screen)
            W(windowID: 11, layer: 8, ownerPID: 12),          // UserNotificationCenter
            W(windowID: 12, layer: 3, ownerPID: 13),          // another app's window
            W(windowID: 13, layer: 2147483630, ownerPID: 14), // Window Server StatusIndicator
            W(windowID: 14, layer: 25, ownerPID: 15),         // a Control Center status item window
        ]
        #expect(ItemClicker.presentationWindowIDs(in: noise, baseline: [], statusWindows: [], ownerPID: app).isEmpty)
    }

    @Test func ignoresBaselineAndOutOfRangeLayers() {
        let windows = [
            W(windowID: 1, layer: 101, ownerPID: 777),       // existed before the click
            W(windowID: 2, layer: 1000, ownerPID: app),      // layer too high
            W(windowID: 3, layer: -20, ownerPID: app),       // negative layer (desktop, etc.)
        ]
        #expect(ItemClicker.presentationWindowIDs(in: windows, baseline: [1], statusWindows: [], ownerPID: app).isEmpty)
    }

    @Test func newWindowsRequireOwnerMatch() {
        let windows = [W(windowID: 1, layer: 101, ownerPID: app),     // the app's menu
                       W(windowID: 2, layer: 25, ownerPID: app),      // the app's popover
                       W(windowID: 3, layer: 101, ownerPID: 777),     // another app's menu: doesn't count
                       W(windowID: 4, layer: 0, ownerPID: app),       // in the baseline
                       W(windowID: 5, layer: 2147483630, ownerPID: app)]
        #expect(ItemClicker.newWindows(in: windows, ownedBy: app, excluding: [4], statusWindows: []) == [1, 2])
        #expect(ItemClicker.newWindows(in: windows, ownedBy: 999, excluding: [], statusWindows: []).isEmpty)
    }

    // macOS 26: all status item windows belong to Control Center; Control Center's own items (Wi-Fi, etc.)
    // also have Control Center as their AX pid.
    let controlCenter: pid_t = 600

    @Test func excludesStatusWindowsAndDragGhostsForControlCenterItems() {
        let windows = [
            W(windowID: 1, layer: 25, ownerPID: controlCenter),  // the clicked item's own status window (off screen before the move, not in the baseline)
            W(windowID: 2, layer: 101, ownerPID: controlCenter), // Control Center's menu
            W(windowID: 3, layer: 500, ownerPID: controlCenter), // ghost window left after a ⌘-drag
            W(windowID: 4, layer: 25, ownerPID: controlCenter),  // Control Center's popover (not a status window)
        ]
        #expect(ItemClicker.presentationWindowIDs(in: windows, baseline: [], statusWindows: [1],
                                                  ownerPID: controlCenter) == [2, 4])
        #expect(ItemClicker.newWindows(in: windows, ownedBy: controlCenter, excluding: [], statusWindows: [1]) == [2, 4])
    }

    @Test func appPopoverOutsideStatusSetIsDetected() {
        let windows = [W(windowID: 1, layer: 25, ownerPID: app),            // the app's popover
                       W(windowID: 2, layer: 25, ownerPID: controlCenter),  // another status window
                       W(windowID: 3, layer: 101, ownerPID: 777)]           // menu: counts regardless of owner
        #expect(ItemClicker.presentationWindowIDs(in: windows, baseline: [], statusWindows: [2], ownerPID: app) == [1, 3])
        #expect(ItemClicker.newWindows(in: windows, ownedBy: app, excluding: [], statusWindows: [2]) == [1])
    }

    @Test func ownerBasedDetectionIgnoresLayersFrom500() {
        let windows = [W(windowID: 1, layer: 499, ownerPID: app), W(windowID: 2, layer: 500, ownerPID: app),
                       W(windowID: 3, layer: 999, ownerPID: app)]
        #expect(ItemClicker.presentationWindowIDs(in: windows, baseline: [], statusWindows: [], ownerPID: app) == [1])
        #expect(ItemClicker.newWindows(in: windows, ownedBy: app, excluding: [], statusWindows: []) == [1])
    }

    @Test func statusWindowsAreThoseOnAMenuBarRow() {
        func raw(_ id: CGWindowID, _ frame: CGRect, onScreen: Bool = true) -> RawStatusWindow {
            RawStatusWindow(windowID: id, frame: frame, title: "", isOnScreen: onScreen)
        }
        let main = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let external = CGRect(x: 1800, y: 0, width: 1920, height: 1080)
        let below = CGRect(x: 0, y: 1169, width: 1920, height: 1080)
        let windows = [
            raw(1, CGRect(x: 1558, y: 0, width: 29, height: 39)),                    // item on the main display
            raw(2, CGRect(x: -3487, y: 0, width: 29, height: 39), onScreen: false),  // item pushed off screen
            raw(3, CGRect(x: 1369, y: 31, width: 226, height: 106)),                 // popover (layer 25, but not on the menu bar row)
            raw(4, CGRect(x: 3500, y: 0, width: 29, height: 30)),                    // copy on the secondary display
            raw(5, CGRect(x: 100, y: 1169, width: 29, height: 30)),                  // menu bar of the display below
            raw(6, CGRect(x: 100, y: 1169, width: 300, height: 200)),                // tall window touching the lower display's top edge: not a status item
        ]
        #expect(ItemClicker.statusWindowIDs(in: windows, displays: [main, external, below]) == [1, 2, 4, 5])
    }

    @Test func detectsAnyOpenMenu() {
        #expect(ItemClicker.containsMenu([W(windowID: 1, layer: 0, ownerPID: 1), W(windowID: 2, layer: 101, ownerPID: 2)]))
        // Popovers (25), notifications (21) and status items (25) are not menus.
        #expect(!ItemClicker.containsMenu([W(windowID: 1, layer: 25, ownerPID: 1), W(windowID: 2, layer: 21, ownerPID: 2)]))
        #expect(!ItemClicker.containsMenu([]))
    }

    @Test func withoutOwnerOnlyMenusCount() {
        let windows = [W(windowID: 1, layer: 101, ownerPID: 777), W(windowID: 2, layer: 25, ownerPID: app)]
        #expect(ItemClicker.presentationWindowIDs(in: windows, baseline: [], statusWindows: [], ownerPID: nil) == [1])
    }

    /// Returns the scripted window lists in order, then keeps returning the last one.
    final class Script {
        var lists: [[W]]
        var calls = 0
        init(_ lists: [[W]]) { self.lists = lists }
        func next() -> [W] {
            defer { calls += 1 }
            return lists[min(calls, lists.count - 1)]
        }
    }

    func wait(_ script: Script, baseline: Set<CGWindowID> = [100], statusWindows: Set<CGWindowID> = [],
              openTimeout: Duration = .seconds(5), nonMenuCap: Duration = .seconds(5)) async throws -> PresentationOutcome {
        try await ItemClicker.waitForPresentationToClose(
            baseline: baseline, ownerPID: app, openTimeout: openTimeout, nonMenuCap: nonMenuCap,
            openPoll: .milliseconds(1), closePoll: .milliseconds(1), windows: script.next,
            statusWindows: { statusWindows })
    }

    let existing = W(windowID: 100, layer: 0, ownerPID: 1)
    let menu = W(windowID: 200, layer: 101, ownerPID: 500)
    let notification = W(windowID: 300, layer: 21, ownerPID: 2)

    @Test func returnsNotPresentedWhenNothingOpens() async throws {
        let outcome = try await wait(Script([[existing, notification]]), openTimeout: .milliseconds(20))
        #expect(outcome == .notPresented)
    }

    @Test func waitsForPresentedWindowToDisappear() async throws {
        let script = Script([[existing], [existing, menu], [existing, menu], [existing, menu, notification],
                             [existing, notification]])
        let outcome = try await wait(script)
        #expect(outcome == .closed)
        #expect(script.calls == 5)
    }

    @Test func reusedPopoverWindowCountsAsNewWhenNotInBaseline() async throws {
        // A popover reuses the same window each time it shows; once closed it's not in the on-screen list, so it's
        // not in the baseline.
        let outcome = try await wait(Script([[existing, popover], [existing, popover], [existing]]))
        #expect(outcome == .closed)
    }

    @Test func statusWindowAppearingAfterBaselineIsNotAPresentation() async throws {
        // A status item window newly added by the clicked app (owner matches, layer 25, not in the baseline) must
        // not count as a presentation.
        let status = W(windowID: 500, layer: 25, ownerPID: app)
        let outcome = try await wait(Script([[existing, status]]), statusWindows: [500], openTimeout: .milliseconds(20))
        #expect(outcome == .notPresented)
    }

    let popover = W(windowID: 400, layer: 25, ownerPID: 500)

    @Test func menusHaveNoCapButOtherPresentationsDo() {
        let cap: Duration = .seconds(60)
        #expect(ItemClicker.closeWaitLimit(presented: [menu], cap: cap) == nil)
        #expect(ItemClicker.closeWaitLimit(presented: [popover, menu], cap: cap) == nil)
        #expect(ItemClicker.closeWaitLimit(presented: [popover], cap: cap) == cap)
        // The app's own panel (layer 3) is capped as well.
        #expect(ItemClicker.closeWaitLimit(presented: [W(windowID: 5, layer: 3, ownerPID: app)], cap: cap) == cap)
    }

    @Test func popoverTimesOutAfterTheCap() async throws {
        let outcome = try await wait(Script([[existing, popover]]), nonMenuCap: .milliseconds(20))
        #expect(outcome == .timedOut)
    }

    @Test func menuIsAwaitedPastTheCapUntilItCloses() async throws {
        // The menu stays open far longer than the cap (200 polls × ≥ 1 ms ≫ 1 ms cap): still wait until it closes.
        let script = Script([[existing]] + Array(repeating: [existing, menu], count: 200) + [[existing]])
        let outcome = try await wait(script, nonMenuCap: .milliseconds(1))
        #expect(outcome == .closed)
        #expect(script.calls == 202)
    }

    @Test func cancellingAnUncappedMenuWaitThrows() async {
        // Quitting Frost cancels the wait: it must end even if the menu stays open (the caller then moves the icon
        // back).
        let task = Task {
            try await ItemClicker.waitForPresentationToClose(
                baseline: [], ownerPID: 500, openTimeout: .seconds(10), nonMenuCap: .milliseconds(1),
                openPoll: .milliseconds(1), closePoll: .milliseconds(5),
                windows: { [W(windowID: 200, layer: 101, ownerPID: 500)] }, statusWindows: { [] })
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cancellationThrows() async {
        let task = Task {
            try await ItemClicker.waitForPresentationToClose(
                baseline: [], ownerPID: 500, openTimeout: .seconds(10), nonMenuCap: .seconds(10),
                openPoll: .seconds(5), closePoll: .seconds(5), windows: { [] }, statusWindows: { [] })
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func parsesWindowFramesAndAlpha() {
        let bounds = CGRect(x: 1369, y: 31, width: 226, height: 106).dictionaryRepresentation as NSDictionary
        let list: [[String: Any]] = [
            [kCGWindowNumber as String: 7, kCGWindowLayer as String: 25, kCGWindowOwnerPID as String: 500,
             kCGWindowBounds as String: bounds, kCGWindowAlpha as String: 0.4],
        ]
        let parsed = ItemClicker.windowInfos(from: list)
        #expect(parsed == [W(windowID: 7, layer: 25, ownerPID: 500, frame: CGRect(x: 1369, y: 31, width: 226, height: 106),
                             alpha: 0.4)])
        #expect(ItemClicker.isFading(parsed))
        #expect(!ItemClicker.isFading([W(windowID: 8, layer: 25, ownerPID: 500)]))
    }

    @Test func splitsOwnerWindowsIntoPresentationAndOthers() {
        let popoverFrame = CGRect(x: 1369, y: 31, width: 226, height: 106)
        let mainFrame = CGRect(x: 100, y: 200, width: 600, height: 400)
        let windows = [
            W(windowID: 1, layer: 25, ownerPID: app, frame: popoverFrame),                  // popover (appeared after the click)
            W(windowID: 2, layer: 0, ownerPID: app, frame: mainFrame),                      // main window already open before the click
            W(windowID: 3, layer: 25, ownerPID: app, frame: CGRect(x: 1460, y: 0, width: 29, height: 30)), // status window
            W(windowID: 4, layer: 0, ownerPID: 777, frame: CGRect(x: 0, y: 0, width: 50, height: 50)),     // another app
            W(windowID: 5, layer: 2147483630, ownerPID: app, frame: .zero),                 // layer too high
        ]
        let frames = ItemClicker.ownerWindowFrames(in: windows, ownerPID: app, baseline: [2], statusWindows: [3])
        #expect(frames == OwnerWindowFrames(presentation: [popoverFrame], other: [mainFrame]))
    }

    /// Records calls to `NonMenuPresentationHooks`.
    actor HookLog {
        var presented: [Set<CGWindowID>] = []
        var polls: [Bool] = []
        var giveUpAfter: Int?
        init(giveUpAfter: Int? = nil) { self.giveUpAfter = giveUpAfter }
        func didPresent(_ ids: Set<CGWindowID>) { presented.append(ids) }
        func poll(_ fading: Bool) -> Bool {
            polls.append(fading)
            return giveUpAfter.map { polls.count >= $0 } ?? false
        }
        var hooks: NonMenuPresentationHooks {
            NonMenuPresentationHooks(presented: { await self.didPresent($0) }, poll: { await self.poll($0) })
        }
    }

    func wait(_ script: Script, hooks: NonMenuPresentationHooks, nonMenuCap: Duration = .seconds(5)) async throws
        -> PresentationOutcome {
        try await ItemClicker.waitForPresentationToClose(
            baseline: [100], ownerPID: app, openTimeout: .seconds(5), nonMenuCap: nonMenuCap,
            openPoll: .milliseconds(1), closePoll: .milliseconds(1), windows: script.next,
            statusWindows: { [] }, nonMenuHooks: hooks)
    }

    @Test func nonMenuHooksRunWhileAPopoverIsOpen() async throws {
        let log = HookLog()
        let fading = W(windowID: 400, layer: 25, ownerPID: 500, alpha: 0.5)
        let script = Script([[existing], [existing, popover], [existing, popover], [existing, fading], [existing]])
        let outcome = try await wait(script, hooks: await log.hooks)
        #expect(outcome == .closed)
        #expect(await log.presented == [[400]])
        // Called once per poll while it's still on screen; not called after it closes.
        #expect(await log.polls == [false, true])
    }

    @Test func nonMenuHooksCanEndTheWait() async throws {
        let log = HookLog(giveUpAfter: 3)
        let outcome = try await wait(Script([[existing, popover]]), hooks: await log.hooks)
        #expect(outcome == .abandoned)
        #expect(await log.polls.count == 3)
    }

    @Test func nonMenuHooksAreNotUsedForMenus() async throws {
        let log = HookLog(giveUpAfter: 1)
        let script = Script([[existing], [existing, menu], [existing, menu], [existing]])
        let outcome = try await wait(script, hooks: await log.hooks)
        #expect(outcome == .closed)
        #expect(await log.presented.isEmpty)
        #expect(await log.polls.isEmpty)
    }

    @Test func capStillAppliesWithHooks() async throws {
        let log = HookLog()
        let outcome = try await wait(Script([[existing, popover]]), hooks: await log.hooks, nonMenuCap: .milliseconds(20))
        #expect(outcome == .timedOut)
    }

    @Test func refusesToClickOffscreenItems() async {
        let hidden = MenuBarItem(windowID: 1, frame: CGRect(x: -3487, y: 0, width: 29, height: 39), isOnScreen: false,
                                 windowTitle: "Item-0", bundleID: "com.example", pid: 500, axDescription: nil)
        await #expect(throws: ItemClickError.notOnScreen) { try await ItemClicker.click(hidden) }
    }
}
