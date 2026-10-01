import CoreGraphics

/// Menu bar geometry of one display (CG global coordinates, top-left origin).
public struct MenuBarDisplay: Hashable, Sendable {
    public var id: CGDirectDisplayID
    public var frame: CGRect
    /// Height of the menu bar window (`screen.frame.maxY − screen.visibleFrame.maxY`; 39 on notched screens, 30 on
    /// regular ones). 0 when the menu bar auto-hides (no height filtering then).
    public var menuBarHeight: CGFloat

    public init(id: CGDirectDisplayID, frame: CGRect, menuBarHeight: CGFloat) {
        self.id = id
        self.frame = frame
        self.menuBarHeight = menuBarHeight
    }
}

/// The **real** window frames of Frost's three controls (CG coordinates, converted by the app layer from
/// `button.window.frame`). nil when unknown.
public struct FrostControlFrames: Hashable, Sendable {
    public var icon: CGRect?
    public var hidden: CGRect?
    public var alwaysHidden: CGRect?

    public init(icon: CGRect?, hidden: CGRect?, alwaysHidden: CGRect?) {
        self.icon = icon
        self.hidden = hidden
        self.alwaysHidden = alwaysHidden
    }
}

/// Picks the set of status windows to manage out of all of them: the real windows on the display that hosts the
/// **active menu bar** (sorted by minX).
///
/// Measured macOS 26 multi-display behaviour (VM + virtual displays inside the guest, `docs/plans/spike-findings.md`,
/// "Multiple displays"):
/// - Every status item has one window on the menu bar of every display. The **real window** (`button.window`, titled
///   with the autosave name, and the one AX coordinates describe) is on the display hosting the active menu bar; the
///   other displays get **replicas** (titled with the bundle ID / pid, empty for Control Center's own items).
/// - When the active menu bar moves to another display (clicking that screen's menu bar, moving focus there), real
///   windows and replicas **swap positions** while windowIDs stay the same. So the display to manage is "the one
///   holding the Frost icon's real window", not necessarily `CGMainDisplayID()`.
/// - A replica = the real window shifted by a fixed per-display offset (right-aligned: about `D.maxX − A.maxX`), with
///   the same width. The only exception is an item whose width differs between real window and replica: at length 0,
///   Frost's separator real window is narrowed to 1 pt (the constraint trick only affects `button.window`) while the
///   replica stays 16 pt, so items to its left shift 15 pt further on the replica. The offset is therefore piecewise,
///   changing at Frost's separators.
/// - Pushed-out items have negative x on every display (replicas are pushed out in "replica coordinates"): on two
///   screens of equal height the two sets of pushed-out windows interleave, all outside every display rect; when a
///   secondary display is to the left (or very wide), real pushed-out items can land inside its rect. Geometry alone
///   can't tell them apart.
///
/// Rules:
/// 1. Active display A: the display holding the Frost icon's real window (matched by the `controls.icon` frame, else by
///    the title `FrostIcon`); if neither is found, the main display (`mainDisplayID`).
/// 2. A's menu bar row: top edge aligned with A's top edge, height equal to A's menu bar height (no height filtering
///    when A's height is 0). Only replicas from other displays with an aligned top edge and equal menu bar height
///    ("same row, same height") stay in this row; when there is no such display (single display, vertically stacked,
///    different heights) this row is the result — with a single display this matches the original filter exactly.
/// 3. Otherwise, for each same-row-same-height display D, find the offset: anchor on the Frost icon (the window on D
///    with the same width, closest to the expected offset `D.maxX − A.maxX`, with the H replica right next to it on
///    the left); without an anchor, take the mode of "spacing between two windows of equal width". The H and AH
///    replicas (right edges aligned) give the per-segment offsets.
/// 4. Pairing: treat each window as a real window; its replica should be at "x + its segment's offset" with the same
///    width. Along the chain "x → x + offset", pair alternately starting from a window without a predecessor
///    (real → replica → real → …), so positions that coincide by accident can still be separated.
/// 5. Windows that can't be paired (e.g. an app whose icon temporarily differs in width between the two screens, or
///    that uses a narrowing trick itself): those abutting an already-classified real window (every menu bar row is a
///    contiguous run) and not abutting a replica are classified real; the reverse are replicas. Those still
///    undecidable: dropped if their center lies inside a same-row-same-height display, otherwise kept (zero-width
///    leftover windows are handled by `StaleWindowFilter`).
///
/// Also returns the frame of the Frost icon replica on every other display (the frozen frame only covers the area left
/// of each screen's snowflake; used to check the cursor position).
public enum MenuBarDisplayResolver {
    public struct Resolution: Equatable, Sendable {
        /// The display hosting the active menu bar (where the real windows are).
        public var display: MenuBarDisplay
        /// The real windows to manage, left to right by minX.
        public var windows: [RawStatusWindow]
        /// Frames (CG) of the Frost icon replicas on other displays, keyed by display ID.
        public var replicaIcons: [CGDirectDisplayID: CGRect]
        /// Number of windows that neither pairing nor abutment could classify and fell back to geometry (diagnostics).
        public var unresolved: Int

        public init(display: MenuBarDisplay, windows: [RawStatusWindow], replicaIcons: [CGDirectDisplayID: CGRect],
                    unresolved: Int) {
            self.display = display
            self.windows = windows
            self.replicaIcons = replicaIcons
            self.unresolved = unresolved
        }
    }

    /// Tolerance for comparing real window and replica positions / widths (measured to be exactly equal).
    static let tolerance: CGFloat = 1
    /// Upper bound on the deviation of an offset from the expected (right-aligned) one: the system items at the right
    /// end of the two screens' menu bars may differ slightly (2 pt measured on real hardware).
    static let maxOffsetDrift: CGFloat = 256
    /// Tolerance for matching Frost controls by frame (same as `FrostControlLocator.tolerance`).
    static let controlTolerance: CGFloat = FrostControlLocator.tolerance

    public static func resolve(windows all: [RawStatusWindow], displays: [MenuBarDisplay],
                               mainDisplayID: CGDirectDisplayID, controls: FrostControlFrames?) -> Resolution? {
        guard !displays.isEmpty else { return nil }
        let located = locateIcon(in: all, displays: displays, frame: controls?.icon)
        let active = located?.display ?? displays.first { $0.id == mainDisplayID } ?? displays[0]
        let row = rowWindows(all, of: active)
        let icon = located.flatMap { hit in row.first { $0.windowID == hit.window.windowID } }
        let peers = displays.filter { $0.id != active.id && isSameRowAndHeight($0, active) }

        var replicaIcons: [CGDirectDisplayID: CGRect] = [:]
        var result = row
        var unresolved = 0
        if !peers.isEmpty {
            let hidden = control(in: row, frame: controls?.hidden, title: FrostControlLocator.hiddenSeparatorTitle)
            let alwaysHidden = control(in: row, frame: controls?.alwaysHidden,
                                       title: FrostControlLocator.alwaysHiddenSeparatorTitle)
            let anchors = Anchors(icon: icon, hidden: hidden, alwaysHidden: alwaysHidden)
            var real: Set<CGWindowID> = []
            var replica: Set<CGWindowID> = []
            for peer in peers {
                guard let segments = offsets(in: row, active: active, peer: peer, anchors: anchors) else { continue }
                if let replicaIcon = segments.replicaIcon { replicaIcons[peer.id] = replicaIcon.frame }
                let pairs = pair(row, segments: segments)
                real.formUnion(pairs.sources)
                replica.formUnion(pairs.targets)
            }
            real.subtract(replica)
            let classified = propagateAlongRow(row, real: real, replica: replica)
            result = row.filter { window in
                if classified.real.contains(window.windowID) { return true }
                if classified.replica.contains(window.windowID) { return false }
                // Zero-width windows (leftovers of quit apps) don't take part in pairing and don't count as
                // undecidable (handled by `StaleWindowFilter`).
                if window.frame.width >= 1 { unresolved += 1 }
                let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
                return !peers.contains { $0.frame.contains(center) }
            }
        }
        if let icon {
            for display in displays where display.id != active.id && replicaIcons[display.id] == nil {
                if let hit = replicaIcon(of: icon, on: display, active: active, in: all) {
                    replicaIcons[display.id] = hit.frame
                }
            }
        }
        return Resolution(display: active, windows: result.sorted { $0.frame.minX < $1.frame.minX },
                          replicaIcons: replicaIcons, unresolved: unresolved)
    }

    // MARK: - Active display and menu bar row

    /// Status windows on a display's menu bar row: top edge aligned, height equal to that display's menu bar height (no
    /// filtering when the height is 0).
    static func rowWindows(_ windows: [RawStatusWindow], of display: MenuBarDisplay) -> [RawStatusWindow] {
        windows.filter {
            abs($0.frame.minY - display.frame.minY) < 1
                && (display.menuBarHeight <= 0 || abs($0.frame.height - display.menuBarHeight) < 1)
        }
    }

    /// Top edge aligned and same menu bar height (treated as equal when either height is unknown): such a display's
    /// replicas stay in the same row as `active`'s real windows.
    static func isSameRowAndHeight(_ display: MenuBarDisplay, _ active: MenuBarDisplay) -> Bool {
        guard abs(display.frame.minY - active.frame.minY) < 1 else { return false }
        return display.menuBarHeight <= 0 || active.menuBarHeight <= 0
            || abs(display.menuBarHeight - active.menuBarHeight) < 1
    }

    /// The Frost icon's real window and its display: matched by frame (±2 pt), else by title (the real window's title
    /// is the autosave name; requires Screen Recording permission). With several candidates, prefer a matching title,
    /// on screen, larger windowID (same as `FrostControlLocator`).
    static func locateIcon(in windows: [RawStatusWindow], displays: [MenuBarDisplay],
                           frame: CGRect?) -> (window: RawStatusWindow, display: MenuBarDisplay)? {
        let title = FrostControlLocator.iconTitle
        var candidates: [RawStatusWindow] = []
        if let frame {
            candidates = windows.filter { matches($0.frame, frame) }
        }
        if candidates.isEmpty { candidates = windows.filter { $0.title == title } }
        let ranked = candidates.sorted { rank($0, title: title) > rank($1, title: title) }
        for window in ranked {
            if let display = display(containingMenuBarWindow: window, in: displays) { return (window, display) }
        }
        return nil
    }

    private static func rank(_ window: RawStatusWindow, title: String) -> (Int, Int, CGWindowID) {
        (window.title == title ? 1 : 0, window.isOnScreen ? 1 : 0, window.windowID)
    }

    private static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.midX - b.midX) <= controlTolerance && abs(a.width - b.width) <= controlTolerance
            && abs(a.minY - b.minY) < 1
    }

    /// The display whose menu bar row holds the window: top edge aligned, center x inside the display (the Frost icon
    /// is always on screen; under the notch it is still within range).
    static func display(containingMenuBarWindow window: RawStatusWindow,
                        in displays: [MenuBarDisplay]) -> MenuBarDisplay? {
        displays.first { display in
            abs(window.frame.minY - display.frame.minY) < 1
                && window.frame.midX >= display.frame.minX && window.frame.midX < display.frame.maxX
        }
    }

    /// One of Frost's separators in the row: by frame (±2 pt), else by title.
    static func control(in row: [RawStatusWindow], frame: CGRect?, title: String) -> RawStatusWindow? {
        if let frame, let hit = row.filter({ matches($0.frame, frame) })
            .max(by: { rank($0, title: title) < rank($1, title: title) }) {
            return hit
        }
        return row.filter { $0.title == title }.max { rank($0, title: title) < rank($1, title: title) }
    }

    // MARK: - Offsets

    struct Anchors {
        var icon: RawStatusWindow?
        var hidden: RawStatusWindow?
        var alwaysHidden: RawStatusWindow?
    }

    /// Per-segment offsets (replica x − real x) for one same-row display: right of H (including H's right edge) is
    /// `right`, between H and AH is `middle`, left of AH is `left`. Also records the replicas of the three controls
    /// (their width may differ from the real window, so they are paired directly).
    struct Segments {
        var right: CGFloat
        var middle: CGFloat
        var left: CGFloat
        var hiddenMaxX: CGFloat?
        var alwaysHiddenMaxX: CGFloat?
        var replicaIcon: RawStatusWindow?
        var fixedPairs: [(real: CGWindowID, replica: CGWindowID)] = []

        /// The offset `window`'s replica should have, treating `window` as a real window.
        func offset(of window: RawStatusWindow) -> CGFloat {
            if let hiddenMaxX, window.frame.minX >= hiddenMaxX - 0.5 { return right }
            if hiddenMaxX == nil { return right }
            if let alwaysHiddenMaxX, window.frame.minX >= alwaysHiddenMaxX - 0.5 { return middle }
            return alwaysHiddenMaxX == nil ? middle : left
        }
    }

    static func offsets(in row: [RawStatusWindow], active: MenuBarDisplay, peer: MenuBarDisplay,
                        anchors: Anchors) -> Segments? {
        let expected = peer.frame.maxX - active.frame.maxX
        var segments: Segments
        if let icon = anchors.icon, let replica = replicaIcon(of: icon, among: row, expected: expected,
                                                               hidden: anchors.hidden) {
            segments = Segments(right: replica.frame.minX - icon.frame.minX, middle: 0, left: 0)
            segments.replicaIcon = replica
            segments.fixedPairs.append((icon.windowID, replica.windowID))
        } else if let mode = modalOffset(in: row, expected: expected) {
            segments = Segments(right: mode, middle: 0, left: 0)
        } else {
            return nil
        }
        segments.middle = segments.right
        segments.left = segments.right
        let taken = Set(segments.fixedPairs.flatMap { [$0.real, $0.replica] })
        if let hidden = anchors.hidden {
            segments.hiddenMaxX = hidden.frame.maxX
            if let replica = separatorReplica(of: hidden, offset: segments.right, in: row, excluding: taken) {
                segments.middle = replica.frame.minX - hidden.frame.minX
                segments.fixedPairs.append((hidden.windowID, replica.windowID))
            }
            segments.left = segments.middle
        }
        if let alwaysHidden = anchors.alwaysHidden, anchors.hidden != nil {
            segments.alwaysHiddenMaxX = alwaysHidden.frame.maxX
            let used = Set(segments.fixedPairs.flatMap { [$0.real, $0.replica] })
            if let replica = separatorReplica(of: alwaysHidden, offset: segments.middle, in: row, excluding: used) {
                segments.left = replica.frame.minX - alwaysHidden.frame.minX
                segments.fixedPairs.append((alwaysHidden.windowID, replica.windowID))
            }
        }
        return segments
    }

    /// The Frost icon's replica in the same row: same width, offset within `maxOffsetDrift` of `expected`; prefer one
    /// with a window right next to it on the left (the H replica; only required when the real H also abuts the icon),
    /// then the one closest to the expected offset.
    static func replicaIcon(of icon: RawStatusWindow, among row: [RawStatusWindow], expected: CGFloat,
                            hidden: RawStatusWindow?) -> RawStatusWindow? {
        let hiddenAdjacent = hidden.map { abs($0.frame.maxX - icon.frame.minX) <= tolerance } ?? false
        let candidates = row.filter { window in
            window.windowID != icon.windowID && abs(window.frame.width - icon.frame.width) <= tolerance
                && abs(window.frame.minX - icon.frame.minX - expected) <= maxOffsetDrift
        }
        func adjacent(_ window: RawStatusWindow) -> Bool {
            row.contains { $0.windowID != window.windowID && abs($0.frame.maxX - window.frame.minX) <= tolerance }
        }
        return candidates.min { a, b in
            let aa = hiddenAdjacent && !adjacent(a) ? 1 : 0, bb = hiddenAdjacent && !adjacent(b) ? 1 : 0
            if aa != bb { return aa < bb }
            return abs(a.frame.minX - icon.frame.minX - expected) < abs(b.frame.minX - icon.frame.minX - expected)
        }
    }

    /// The Frost icon's replica on any other display (possibly a different row): the window on that display's menu bar
    /// row with the same width, closest to the expected right-aligned position.
    static func replicaIcon(of icon: RawStatusWindow, on display: MenuBarDisplay, active: MenuBarDisplay,
                            in all: [RawStatusWindow]) -> RawStatusWindow? {
        let row = rowWindows(all, of: display).filter { $0.windowID != icon.windowID }
        return replicaIcon(of: icon, among: row, expected: display.frame.maxX - active.frame.maxX, hidden: nil)
    }

    /// A separator's replica: right edge at "real right edge + right-segment offset" (items to its right share that
    /// offset). Width may differ (real window 1 pt, replica 16 pt): prefer equal width, then 16 pt width (a length-0
    /// replica); with a single candidate, use it directly.
    static func separatorReplica(of separator: RawStatusWindow, offset: CGFloat, in row: [RawStatusWindow],
                                 excluding taken: Set<CGWindowID>) -> RawStatusWindow? {
        let candidates = row.filter {
            $0.windowID != separator.windowID && !taken.contains($0.windowID)
                && abs($0.frame.maxX - (separator.frame.maxX + offset)) <= tolerance
        }
        if let same = candidates.first(where: { abs($0.frame.width - separator.frame.width) <= tolerance }) {
            return same
        }
        if let zero = candidates.first(where: { abs($0.frame.width - zeroLengthWidth) <= tolerance }) { return zero }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Window width of a `length = 0` status item (the system leaves 16 pt of blank space; only the real window can be
    /// narrowed).
    static let zeroLengthWidth: CGFloat = 16

    /// Without the Frost icon as anchor: the mode of the spacings between pairs of windows of equal (non-zero) width
    /// that are within `maxOffsetDrift` of `expected` (±1 pt counts as the same value). Needs at least 2 supporting
    /// pairs; ties go to the one closest to the expected offset.
    static func modalOffset(in row: [RawStatusWindow], expected: CGFloat) -> CGFloat? {
        var deltas: [CGFloat] = []
        for a in row where a.frame.width >= 1 {
            for b in row where b.windowID != a.windowID && abs(b.frame.width - a.frame.width) <= tolerance {
                let delta = b.frame.minX - a.frame.minX
                if abs(delta - expected) <= maxOffsetDrift { deltas.append(delta) }
            }
        }
        var best: (delta: CGFloat, support: Int)?
        for delta in Set(deltas) {
            let support = deltas.filter { abs($0 - delta) <= tolerance }.count
            guard let current = best else {
                best = (delta, support)
                continue
            }
            if support > current.support
                || (support == current.support && abs(delta - expected) < abs(current.delta - expected))
                || (support == current.support && abs(delta - expected) == abs(current.delta - expected)
                    && delta < current.delta) {
                best = (delta, support)
            }
        }
        guard let best, best.support >= 2 else { return nil }
        return best.delta
    }

    // MARK: - Pairing

    /// Pairs one same-row display: `sources` are real windows, `targets` are that display's replicas.
    static func pair(_ row: [RawStatusWindow],
                     segments: Segments) -> (sources: Set<CGWindowID>, targets: Set<CGWindowID>) {
        var sources = Set(segments.fixedPairs.map(\.real))
        var targets = Set(segments.fixedPairs.map(\.replica))
        let fixed = sources.union(targets)
        let nodes = row.filter { $0.frame.width >= 1 && !fixed.contains($0.windowID) }
        // For each window (treated as real), the window at its replica position: same width, x within 1 pt; take the
        // closest (ties go to the smaller windowID).
        var successor: [CGWindowID: CGWindowID] = [:]
        var predecessor: [CGWindowID: (id: CGWindowID, error: CGFloat)] = [:]
        for node in nodes {
            let target = node.frame.minX + segments.offset(of: node)
            let hit = nodes
                .filter { $0.windowID != node.windowID && abs($0.frame.width - node.frame.width) <= tolerance
                    && abs($0.frame.minX - target) <= tolerance }
                .min { (abs($0.frame.minX - target), $0.windowID) < (abs($1.frame.minX - target), $1.windowID) }
            guard let hit else { continue }
            let error = abs(hit.frame.minX - target)
            // At most one predecessor per window: smaller error wins, ties go to the smaller windowID.
            if let existing = predecessor[hit.windowID],
               (existing.error, existing.id) <= (error, node.windowID) { continue }
            if let existing = predecessor[hit.windowID] { successor[existing.id] = nil }
            predecessor[hit.windowID] = (node.windowID, error)
            successor[node.windowID] = hit.windowID
        }
        // Mark alternately along each chain, starting from windows without a predecessor: real → replica → real → …
        var visited: Set<CGWindowID> = []
        for node in nodes where predecessor[node.windowID] == nil {
            var current: CGWindowID? = node.windowID
            var isSource = true
            while let id = current, !visited.contains(id) {
                visited.insert(id)
                guard let next = successor[id] else { break }
                if isSource {
                    sources.insert(id)
                    targets.insert(next)
                }
                isSource.toggle()
                current = next
            }
        }
        return (sources, targets)
    }

    /// Abutment propagation: an unclassified window that abuts only real windows (`maxX == other minX` or
    /// `minX == other maxX`, ±1 pt) is real; one that abuts only replicas is a replica; those abutting both or neither
    /// are left for the geometric fallback. Repeats until nothing changes.
    static func propagateAlongRow(_ row: [RawStatusWindow], real: Set<CGWindowID>,
                                  replica: Set<CGWindowID>) -> (real: Set<CGWindowID>, replica: Set<CGWindowID>) {
        var real = real, replica = replica
        let byID = Dictionary(row.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        func touches(_ window: RawStatusWindow, _ set: Set<CGWindowID>) -> Bool {
            set.contains { id in
                guard let other = byID[id], other.windowID != window.windowID, other.frame.width >= 1 else { return false }
                return abs(window.frame.maxX - other.frame.minX) <= tolerance
                    || abs(window.frame.minX - other.frame.maxX) <= tolerance
            }
        }
        var changed = true
        while changed {
            changed = false
            for window in row where window.frame.width >= 1
                && !real.contains(window.windowID) && !replica.contains(window.windowID) {
                let toReal = touches(window, real), toReplica = touches(window, replica)
                if toReal != toReplica {
                    if toReal { real.insert(window.windowID) } else { replica.insert(window.windowID) }
                    changed = true
                }
            }
        }
        return (real, replica)
    }
}
