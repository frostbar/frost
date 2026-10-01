import Testing
import CoreGraphics
@testable import FrostCore

/// Fixtures: the first groups are window lists measured in the VM (macOS 26.6.2, main display 1728×1117 with a 30 pt
/// menu bar, guest virtual display `scripts/vm/guest-virtual-display.m` 1920×1080 also with a 30 pt menu bar;
/// FakeItems A + B running); the rest are synthesized following the same rules.
@Suite struct MenuBarDisplayResolverTests {
    static let main = MenuBarDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), menuBarHeight: 30)

    /// (x, width, windowID, title), y = 0, height 30; on-screen state is decided by `onScreen`.
    typealias Row = [(x: CGFloat, w: CGFloat, id: CGWindowID, title: String)]

    static func windows(_ row: Row, y: CGFloat = 0, height: CGFloat = 30,
                        onScreen: (CGRect) -> Bool = { $0.minX >= -1920 && $0.maxX <= 3648 }) -> [RawStatusWindow] {
        row.map { entry in
            let frame = CGRect(x: entry.x, y: y, width: entry.w, height: height)
            return RawStatusWindow(windowID: entry.id, frame: frame, title: entry.title, isOnScreen: onScreen(frame))
        }
    }

    static func controls(_ windows: [RawStatusWindow], icon: CGWindowID, hidden: CGWindowID,
                         alwaysHidden: CGWindowID) -> FrostControlFrames {
        func frame(_ id: CGWindowID) -> CGRect? { windows.first { $0.windowID == id }?.frame }
        return FrostControlFrames(icon: frame(icon), hidden: frame(hidden), alwaysHidden: frame(alwaysHidden))
    }

    static func ids(_ resolution: MenuBarDisplayResolver.Resolution?) -> [CGWindowID] {
        resolution?.windows.map(\.windowID) ?? []
    }

    // MARK: - Measured in the VM: collapsed, secondary display on the right (same 30 pt height)

    static let right = MenuBarDisplay(id: 2, frame: CGRect(x: 1728, y: 0, width: 1920, height: 1080), menuBarHeight: 30)

    /// Real window titles are autosave names, replicas are bundle IDs (empty for Control Center's own items).
    /// Replica = real x + 1920.
    static let collapsedRight: Row = [
        (-9080, 49, 82, "FIPercent"), (-9031, 5016, 70, "FrostAlwaysHiddenSeparator"),
        (-7160, 49, 83, "dev.frost.FakeItems"), (-7111, 5016, 71, "dev.frost.Frost"),
        (-4015, 32, 32, "Item-0"), (-3983, 37, 92, "FBTwo"), (-3946, 32, 90, "FBLeaf"), (-3914, 64, 86, "FIBeta"),
        (-3850, 32, 80, "FINoop"), (-3818, 36, 78, "FIPopover"), (-3782, 110, 74, "FIWide"),
        (-3672, 29, 72, "FIMenuA"), (-3643, 36, 88, "FIClock"), (-3607, 5016, 68, "FrostHiddenSeparator"),
        (-2095, 32, 45, "com.apple.Spotlight"), (-2063, 37, 93, "dev.frost.FakeItemsB"),
        (-2026, 32, 91, "dev.frost.FakeItemsB"), (-1994, 64, 87, "dev.frost.FakeItems"),
        (-1930, 32, 81, "dev.frost.FakeItems"), (-1898, 36, 79, "dev.frost.FakeItems"),
        (-1862, 110, 75, "dev.frost.FakeItems"), (-1752, 29, 73, "dev.frost.FakeItems"),
        (-1723, 36, 89, "dev.frost.FakeItems"), (-1687, 5016, 69, "dev.frost.Frost"),
        (1409, 38, 66, "FrostIcon"), (1447, 29, 84, "FIBolt"), (1476, 33, 76, "FIStar"),
        (1509, 42, 30, "BentoBox-0"), (1551, 177, 29, "Clock"),
        (3329, 38, 67, "dev.frost.Frost"), (3367, 29, 85, "dev.frost.FakeItems"),
        (3396, 33, 77, "dev.frost.FakeItems"), (3429, 42, 44, ""), (3471, 177, 42, ""),
    ]
    static let collapsedRightReal: [CGWindowID] = [82, 70, 32, 92, 90, 86, 80, 78, 74, 72, 88, 68, 66, 84, 76, 30, 29]

    @Test func sameHeightDisplayOnTheRight() {
        let all = Self.windows(Self.collapsedRight)
        let r = MenuBarDisplayResolver.resolve(windows: all, displays: [Self.main, Self.right], mainDisplayID: 1,
                                               controls: Self.controls(all, icon: 66, hidden: 68, alwaysHidden: 70))
        #expect(r?.display == Self.main)
        #expect(Self.ids(r) == Self.collapsedRightReal)
        #expect(r?.unresolved == 0)
        #expect(r?.replicaIcons == [2: CGRect(x: 3329, y: 0, width: 38, height: 30)])

        // The old rule (height + "center not inside another display") would keep the pushed-out replicas
        // (x ≈ −2000, outside every display): duplicates.
        let legacy = all.filter { w in
            !Self.right.frame.contains(CGPoint(x: w.frame.midX, y: w.frame.midY))
        }
        #expect(legacy.count > Self.collapsedRightReal.count)
    }

    @Test func withoutControlFramesFallsBackToTitlesThenToTheModalOffset() {
        let all = Self.windows(Self.collapsedRight)
        // No frames: find FrostIcon / the separators by title.
        let byTitle = MenuBarDisplayResolver.resolve(windows: all, displays: [Self.main, Self.right],
                                                     mainDisplayID: 1, controls: nil)
        #expect(Self.ids(byTitle) == Self.collapsedRightReal)
        // No titles either (no Screen Recording permission): use the main display; the offset is the mode of
        // "spacing between equal-width windows" (+1920).
        let untitled = all.map { RawStatusWindow(windowID: $0.windowID, frame: $0.frame, title: "",
                                                 isOnScreen: $0.isOnScreen) }
        let bare = MenuBarDisplayResolver.resolve(windows: untitled, displays: [Self.main, Self.right],
                                                  mainDisplayID: 1, controls: nil)
        #expect(bare?.display == Self.main)
        #expect(Self.ids(bare) == Self.collapsedRightReal)
        #expect(MenuBarDisplayResolver.modalOffset(in: untitled, expected: 1920) == 1920)
    }

    @Test func staleControlFramesStillFindTheIconByTitle() {
        let all = Self.windows(Self.collapsedRight)
        let stale = FrostControlFrames(icon: CGRect(x: 700, y: 0, width: 38, height: 30), hidden: nil,
                                       alwaysHidden: nil)
        let r = MenuBarDisplayResolver.resolve(windows: all, displays: [Self.main, Self.right], mainDisplayID: 1,
                                               controls: stale)
        #expect(Self.ids(r) == Self.collapsedRightReal)
    }

    // MARK: - Measured in the VM: expanded (H's real window is 1 pt, its replica 16 pt)

    static let expandedRight: Row = [
        (-4085, 49, 328, "FIPercent"), (-4036, 5016, 70, "FrostAlwaysHiddenSeparator"),
        (-2180, 49, 329, "dev.frost.FakeItems"), (-2131, 5016, 286, "dev.frost.Frost"),
        (980, 32, 32, "Item-0"), (1012, 37, 92, "FBTwo"), (1049, 32, 90, "FBLeaf"), (1081, 64, 332, "FIBeta"),
        (1145, 32, 326, "FINoop"), (1177, 36, 324, "FIPopover"), (1213, 110, 320, "FIWide"),
        (1323, 29, 318, "FIMenuA"), (1352, 56, 334, "FIClock"), (1408, 1, 68, "FrostHiddenSeparator"),
        (1409, 38, 66, "FrostIcon"), (1447, 29, 330, "FIBolt"), (1476, 33, 322, "FIStar"),
        (1509, 42, 30, "BentoBox-0"), (1551, 177, 29, "Clock"),
        (2885, 32, 278, "com.apple.Spotlight"), (2917, 37, 297, "dev.frost.FakeItemsB"),
        (2954, 32, 296, "dev.frost.FakeItemsB"), (2986, 64, 333, "dev.frost.FakeItems"),
        (3050, 32, 327, "dev.frost.FakeItems"), (3082, 36, 325, "dev.frost.FakeItems"),
        (3118, 110, 321, "dev.frost.FakeItems"), (3228, 29, 319, "dev.frost.FakeItems"),
        (3257, 56, 335, "dev.frost.FakeItems"), (3313, 16, 285, "dev.frost.Frost"), (3329, 38, 282, "dev.frost.Frost"),
        (3367, 29, 331, "dev.frost.FakeItems"), (3396, 33, 323, "dev.frost.FakeItems"),
        (3429, 42, 272, ""), (3471, 177, 267, ""),
    ]

    @Test func separatorWidthDifferenceShiftsTheOffsetOfItemsLeftOfIt() {
        let all = Self.windows(Self.expandedRight)
        let r = MenuBarDisplayResolver.resolve(windows: all, displays: [Self.main, Self.right], mainDisplayID: 1,
                                               controls: Self.controls(all, icon: 66, hidden: 68, alwaysHidden: 70))
        #expect(Self.ids(r) == [328, 70, 32, 92, 90, 332, 326, 324, 320, 318, 334, 68, 66, 330, 322, 30, 29])
        #expect(r?.unresolved == 0)
        let row = MenuBarDisplayResolver.rowWindows(all, of: Self.main)
        let byID = Dictionary(uniqueKeysWithValues: row.map { ($0.windowID, $0) })
        let segments = MenuBarDisplayResolver.offsets(
            in: row, active: Self.main, peer: Self.right,
            anchors: .init(icon: byID[66], hidden: byID[68], alwaysHidden: byID[70]))
        #expect(segments?.right == 1920)
        #expect(segments?.middle == 1905)
        #expect(segments?.left == 1905)
    }

    // MARK: - Measured in the VM: secondary display on the left

    static let collapsedLeft: Row = [
        (-10815, 49, 135, "dev.frost.FakeItems"), (-10766, 5016, 129, "dev.frost.Frost"),
        (-9087, 49, 82, "FIPercent"), (-9038, 5016, 70, "FrostAlwaysHiddenSeparator"),
        (-5750, 32, 120, "com.apple.Spotlight"), (-5718, 37, 144, "dev.frost.FakeItemsB"),
        (-5681, 32, 143, "dev.frost.FakeItemsB"), (-5649, 64, 141, "dev.frost.FakeItems"),
        (-5585, 32, 134, "dev.frost.FakeItems"), (-5553, 36, 133, "dev.frost.FakeItems"),
        (-5517, 110, 131, "dev.frost.FakeItems"), (-5407, 29, 130, "dev.frost.FakeItems"),
        (-5378, 43, 142, "dev.frost.FakeItems"), (-5335, 5016, 128, "dev.frost.Frost"),
        (-4022, 32, 32, "Item-0"), (-3990, 37, 92, "FBTwo"), (-3953, 32, 90, "FBLeaf"), (-3921, 64, 86, "FIBeta"),
        (-3857, 32, 80, "FINoop"), (-3825, 36, 78, "FIPopover"), (-3789, 110, 74, "FIWide"),
        (-3679, 29, 72, "FIMenuA"), (-3650, 43, 88, "FIClock"), (-3607, 5016, 68, "FrostHiddenSeparator"),
        (-319, 38, 126, "dev.frost.Frost"), (-281, 29, 140, "dev.frost.FakeItems"),
        (-252, 33, 132, "dev.frost.FakeItems"), (-219, 42, 119, ""), (-177, 177, 113, ""),
        (1409, 38, 66, "FrostIcon"), (1447, 29, 84, "FIBolt"), (1476, 33, 76, "FIStar"),
        (1509, 42, 30, "BentoBox-0"), (1551, 177, 29, "Clock"),
    ]

    @Test func sameHeightDisplayOnTheLeft() {
        let left = MenuBarDisplay(id: 3, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), menuBarHeight: 30)
        let all = Self.windows(Self.collapsedLeft)
        let r = MenuBarDisplayResolver.resolve(windows: all, displays: [Self.main, left], mainDisplayID: 1,
                                               controls: Self.controls(all, icon: 66, hidden: 68, alwaysHidden: 70))
        #expect(Self.ids(r) == Self.collapsedRightReal)
        #expect(r?.replicaIcons == [3: CGRect(x: -319, y: 0, width: 38, height: 30)])
    }

    @Test func wideDisplayOnTheLeftContainsRealPushedOutItems() {
        // A 5120 pt wide display on the left: the real pushed-out items (x −4022 … −3607) fall inside its rect, and
        // the old rule would drop them.
        let wide = MenuBarDisplay(id: 4, frame: CGRect(x: -5120, y: 0, width: 5120, height: 1440), menuBarHeight: 30)
        let all = Self.windows(Self.collapsedLeft)
        let r = MenuBarDisplayResolver.resolve(windows: all, displays: [Self.main, wide], mainDisplayID: 1,
                                               controls: Self.controls(all, icon: 66, hidden: 68, alwaysHidden: 70))
        #expect(Self.ids(r) == Self.collapsedRightReal)
        let pushedOut = r?.windows.filter { wide.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        #expect(pushedOut?.map(\.windowID) == [32, 92, 90, 86, 80, 78, 74, 72, 88, 68])
    }

    // MARK: - Measured in the VM: displays stacked vertically

    @Test func verticallyStackedDisplaysUseSeparateRows() {
        let below = MenuBarDisplay(id: 5, frame: CGRect(x: 0, y: 1117, width: 1920, height: 1080), menuBarHeight: 30)
        let mainRow = Self.windows(Self.collapsedRight.filter { Self.collapsedRightReal.contains($0.id) })
        // Replicas on the lower display: y = 1117, offset 1920 − 1728 = 192 (pushed-out ones are on its row too).
        let belowRow = Self.windows([
            (-8896, 49, 242, "dev.frost.FakeItems"), (-8847, 5016, 232, "dev.frost.Frost"),
            (-3831, 32, 227, "com.apple.Spotlight"), (-3415, 5016, 231, "dev.frost.Frost"),
            (1601, 38, 228, "dev.frost.Frost"), (1639, 29, 243, "dev.frost.FakeItems"),
            (1701, 42, 222, ""), (1743, 177, 216, ""),
        ], y: 1117)
        let all = mainRow + belowRow
        let r = MenuBarDisplayResolver.resolve(windows: all, displays: [Self.main, below], mainDisplayID: 1,
                                               controls: Self.controls(all, icon: 66, hidden: 68, alwaysHidden: 70))
        #expect(Self.ids(r) == Self.collapsedRightReal)
        #expect(r?.replicaIcons == [5: CGRect(x: 1601, y: 1117, width: 38, height: 30)])
    }

    // MARK: - Active menu bar on the secondary display (real windows and replicas swapped)

    @Test func followsTheRealWindowsToTheActiveMenuBar() {
        // After clicking the secondary display's menu bar, the real windows (`button.window`) move to the secondary
        // display and the main display gets the replicas. Reusing the collapsed positions here: the real windows are
        // the group at x ≥ 1728 and −2095 … −1687, −7160 ….
        let swapped: Row = Self.collapsedRight.map { entry in
            let isMainSide = Self.collapsedRightReal.contains(entry.id)
            return (entry.x, entry.w, entry.id, isMainSide ? "com.example.replica" : "Real-\(entry.id)")
        }
        let all = Self.windows(swapped)
        let r = MenuBarDisplayResolver.resolve(windows: all, displays: [Self.main, Self.right], mainDisplayID: 1,
                                               controls: Self.controls(all, icon: 67, hidden: 69, alwaysHidden: 71))
        #expect(r?.display == Self.right)
        #expect(Self.ids(r) == [83, 71, 45, 93, 91, 87, 81, 79, 75, 73, 89, 69, 67, 85, 77, 44, 42])
        #expect(r?.replicaIcons == [1: CGRect(x: 1409, y: 0, width: 38, height: 30)])
    }

    @Test func activeSecondaryDisplayInTheExpandedState() {
        // Real windows on the right display, expanded: the real H is 1 pt (on the secondary display), the replica on
        // the main display is 16 pt.
        var bar = SyntheticBar()
        let all = bar.real(on: Self.right, state: .expanded) + bar.replicas(on: Self.main, state: .expanded)
        let r = MenuBarDisplayResolver.resolve(windows: all, displays: [Self.main, Self.right], mainDisplayID: 1,
                                               controls: bar.controls)
        #expect(r?.display == Self.right)
        #expect(Self.ids(r) == bar.realIDs)
        #expect(r?.unresolved == 0)
    }

    // MARK: - Synthesized

    @Test func expandedAllShiftsBothSegments() {
        var bar = SyntheticBar()
        let all = bar.real(on: Self.main, state: .expandedAll) + bar.replicas(on: Self.right, state: .expandedAll)
        let r = MenuBarDisplayResolver.resolve(windows: all, displays: [Self.main, Self.right], mainDisplayID: 1,
                                               controls: bar.controls)
        #expect(Self.ids(r) == bar.realIDs)
        #expect(r?.unresolved == 0)
    }

    @Test func editingStateHasEqualWidthsEverywhere() {
        var bar = SyntheticBar()
        let all = bar.real(on: Self.main, state: .editing) + bar.replicas(on: Self.right, state: .editing)
        let r = MenuBarDisplayResolver.resolve(windows: all, displays: [Self.main, Self.right], mainDisplayID: 1,
                                               controls: bar.controls)
        #expect(Self.ids(r) == bar.realIDs)
    }

    @Test func threeDisplaysInARow() {
        let left = MenuBarDisplay(id: 3, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), menuBarHeight: 30)
        for state in SyntheticBar.State.allCases {
            var bar = SyntheticBar()
            let all = bar.real(on: Self.main, state: state)
                + bar.replicas(on: Self.right, state: state)
                + bar.replicas(on: left, state: state)
            let r = MenuBarDisplayResolver.resolve(windows: all, displays: [left, Self.main, Self.right],
                                                   mainDisplayID: 1, controls: bar.controls)
            #expect(Self.ids(r) == bar.realIDs, "state \(state)")
            #expect(r?.replicaIcons.keys.sorted() == [2, 3], "state \(state)")
        }
    }

    @Test func itemWhoseReplicaHasADifferentWidthIsResolvedByAdjacency() {
        // Some app's icon temporarily has different widths on the two screens (or it narrows its own real window
        // too): every replica to its left is shifted 7 pt further, can't be paired, and is classified by
        // "every row is a contiguous run".
        var bar = SyntheticBar()
        bar.replicaWidthOverride = ["Clockish": 43]
        let all = bar.real(on: Self.main, state: .collapsed) + bar.replicas(on: Self.right, state: .collapsed)
        let r = MenuBarDisplayResolver.resolve(windows: all, displays: [Self.main, Self.right], mainDisplayID: 1,
                                               controls: bar.controls)
        #expect(Self.ids(r) == bar.realIDs)
        #expect(r?.unresolved == 0)
    }

    @Test func coincidentalReplicaPositionIsSeparatedByTheChain() {
        // Real window C happens to sit one more offset past A's replica A′: A′ also "has a replica" (namely C).
        // Pairing alternately along the chain A → A′ → C → C′ gives (A, A′), (C, C′); without alternation A′ would be
        // taken for a real window.
        func window(_ id: CGWindowID, _ x: CGFloat) -> RawStatusWindow {
            RawStatusWindow(windowID: id, frame: CGRect(x: x, y: 0, width: 30, height: 30), title: "", isOnScreen: false)
        }
        let row = [window(1, -6000), window(2, -4080), window(3, -2160), window(4, -240)]
        let segments = MenuBarDisplayResolver.Segments(right: 1920, middle: 1920, left: 1920)
        let pairs = MenuBarDisplayResolver.pair(row, segments: segments)
        #expect(pairs.sources == [1, 3])
        #expect(pairs.targets == [2, 4])
    }

    @Test func adjacencyNeedsAnUnambiguousNeighbour() {
        func window(_ id: CGWindowID, _ x: CGFloat, _ width: CGFloat = 30) -> RawStatusWindow {
            RawStatusWindow(windowID: id, frame: CGRect(x: x, y: 0, width: width, height: 30), title: "",
                            isOnScreen: false)
        }
        // 5 abuts real 1 on its left, 6 abuts 5 on its left (transitively), 7 abuts replica 2 on its right; 8 abuts
        // both real 1 and replica 3: undecided.
        let row = [window(1, 100), window(2, 300), window(3, 160, 20), window(5, 70), window(6, 40),
                   window(7, 330), window(8, 130)]
        let r = MenuBarDisplayResolver.propagateAlongRow(row, real: [1], replica: [2, 3])
        #expect(r.real == [1, 5, 6])
        #expect(r.replica == [2, 3, 7])
    }

    @Test func differentMenuBarHeightsNeedNoPairingAndKeepPushedOutItemsInsideOtherDisplays() {
        // The notched screen (39 pt) is the active display, the external display (30 pt) is on the left and very
        // wide: replicas are already separated by height; real pushed-out items falling inside its rect are kept too
        // (the old rule would drop them).
        let notched = MenuBarDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1800, height: 1169), menuBarHeight: 39)
        let external = MenuBarDisplay(id: 2, frame: CGRect(x: -5120, y: 0, width: 5120, height: 1440), menuBarHeight: 30)
        let real = Self.windows([(-3487, 29, 1, "X"), (-3458, 5016, 2, "FrostHiddenSeparator"),
                                 (1558, 29, 3, "FrostIcon"), (1587, 29, 4, "V")], height: 39)
        let replicas = Self.windows([(-3487 - 1800, 29, 11, "b"), (-3458 - 1800, 5016, 12, "dev.frost.Frost"),
                                     (-242, 29, 13, "dev.frost.Frost"), (-213, 29, 14, "b")], height: 30)
        let r = MenuBarDisplayResolver.resolve(windows: real + replicas, displays: [notched, external], mainDisplayID: 1,
                                               controls: FrostControlFrames(icon: real[2].frame, hidden: real[1].frame,
                                                                            alwaysHidden: nil))
        #expect(Self.ids(r) == [1, 2, 3, 4])
        #expect(r?.replicaIcons == [2: CGRect(x: -242, y: 0, width: 29, height: 30)])
    }

    // MARK: - Single display: identical to the original filter

    let single = MenuBarDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1800, height: 1169), menuBarHeight: 39)

    func w(_ id: CGWindowID, x: CGFloat, width: CGFloat = 30, y: CGFloat = 0, height: CGFloat = 39,
           onScreen: Bool = true, title: String = "") -> RawStatusWindow {
        RawStatusWindow(windowID: id, frame: CGRect(x: x, y: y, width: width, height: height), title: title,
                        isOnScreen: onScreen)
    }

    func resolveSingle(_ windows: [RawStatusWindow], height: CGFloat = 39) -> [CGWindowID] {
        var display = single
        display.menuBarHeight = height
        return Self.ids(MenuBarDisplayResolver.resolve(windows: windows, displays: [display], mainDisplayID: 1,
                                                       controls: nil))
    }

    @Test func singleDisplayKeepsTheMenuBarRowSortedLeftToRight() {
        #expect(resolveSingle([w(2, x: 900), w(1, x: 500), w(3, x: -9000, onScreen: false)]) == [3, 1, 2])
    }

    @Test func singleDisplayDropsWindowsOffTheMenuBarRow() {
        #expect(resolveSingle([w(1, x: 500, y: 400), w(2, x: 600, y: 31, height: 106)]).isEmpty)
    }

    @Test func singleDisplayFiltersByMenuBarHeightUnlessItIsUnknown() {
        #expect(resolveSingle([w(1, x: 500), w(2, x: 600, height: 24)]) == [1])
        // Height is 0 when the menu bar auto-hides: no height filtering.
        #expect(resolveSingle([w(1, x: 500), w(2, x: 600, height: 24)], height: 0) == [1, 2])
    }

    @Test func singleDisplayKeepsItemsUnderTheNotch() {
        let r = MenuBarDisplayResolver.resolve(windows: [w(1, x: 907, onScreen: false), w(2, x: 1558)],
                                               displays: [single], mainDisplayID: 1, controls: nil)
        #expect(r?.windows.map(\.isOnScreen) == [false, true])
    }

    @Test func noDisplaysMeansNoResolution() {
        #expect(MenuBarDisplayResolver.resolve(windows: [w(1, x: 0)], displays: [], mainDisplayID: 1,
                                               controls: nil) == nil)
    }
}

/// A synthesized menu bar: `[2 AH-section items][AH][3 hidden-section items][H][Frost icon][1 visible item]
/// [Control Center][clock]`, right-aligned on every screen and contiguous. Separator widths by state: collapsed 5016;
/// expanded: H has length 0 (real window 1 pt, replica 16 pt); expanded all: both H and AH; editing: both 24.
struct SyntheticBar {
    enum State: CaseIterable { case collapsed, expanded, expandedAll, editing }

    struct Item {
        var id: CGWindowID
        var title: String
        var width: CGFloat
    }

    var replicaWidthOverride: [String: CGFloat] = [:]
    private(set) var controls: FrostControlFrames?
    private(set) var realIDs: [CGWindowID] = []
    private var nextReplicaID: CGWindowID = 1000

    static let items: [Item] = [
        Item(id: 1, title: "AlwaysA", width: 49), Item(id: 2, title: "AlwaysB", width: 32),
        Item(id: 3, title: "FrostAlwaysHiddenSeparator", width: 0),
        Item(id: 4, title: "HiddenA", width: 37), Item(id: 5, title: "Clockish", width: 36),
        Item(id: 6, title: "HiddenC", width: 110),
        Item(id: 7, title: "FrostHiddenSeparator", width: 0),
        Item(id: 8, title: "FrostIcon", width: 38), Item(id: 9, title: "Visible", width: 29),
        Item(id: 10, title: "BentoBox-0", width: 42), Item(id: 11, title: "Clock", width: 177),
    ]

    static func separatorWidths(_ state: State, real: Bool) -> (hidden: CGFloat, alwaysHidden: CGFloat) {
        let zero: CGFloat = real ? 1 : 16
        switch state {
        case .collapsed: return (5016, 5016)
        case .expanded: return (zero, 5016)
        case .expandedAll: return (zero, zero)
        case .editing: return (24, 24)
        }
    }

    private func layout(on display: MenuBarDisplay, state: State, real: Bool) -> [(Item, CGRect)] {
        let widths = Self.separatorWidths(state, real: real)
        var x = display.frame.maxX
        var result: [(Item, CGRect)] = []
        for item in Self.items.reversed() {
            var width = item.width
            if item.title == "FrostHiddenSeparator" { width = widths.hidden }
            if item.title == "FrostAlwaysHiddenSeparator" { width = widths.alwaysHidden }
            if !real, let override = replicaWidthOverride[item.title] { width = override }
            x -= width
            result.append((item, CGRect(x: x, y: display.frame.minY, width: width, height: display.menuBarHeight)))
        }
        return result.reversed()
    }

    mutating func real(on display: MenuBarDisplay, state: State) -> [RawStatusWindow] {
        let laid = layout(on: display, state: state, real: true)
        func frame(_ title: String) -> CGRect? { laid.first { $0.0.title == title }?.1 }
        controls = FrostControlFrames(icon: frame("FrostIcon"), hidden: frame("FrostHiddenSeparator"),
                                      alwaysHidden: frame("FrostAlwaysHiddenSeparator"))
        realIDs = laid.map(\.0.id)
        return laid.map { item, frame in
            RawStatusWindow(windowID: item.id, frame: frame, title: item.title,
                            isOnScreen: frame.minX >= display.frame.minX)
        }
    }

    mutating func replicas(on display: MenuBarDisplay, state: State) -> [RawStatusWindow] {
        layout(on: display, state: state, real: false).map { item, frame in
            nextReplicaID += 1
            return RawStatusWindow(windowID: nextReplicaID, frame: frame, title: "dev.example",
                                   isOnScreen: frame.minX >= display.frame.minX)
        }
    }
}
