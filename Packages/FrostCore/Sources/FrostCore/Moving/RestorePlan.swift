import CoreGraphics

/// When Frost Bar forwards a click, a hidden item is temporarily moved to the visible section; `RestorePlan`
/// records its position in its original section so it can be moved back afterwards.
///
/// Candidate destinations, in priority order:
/// 1. Right neighbour within the original section → `.leftOf(rightNeighbour)`;
/// 2. Left neighbour within the original section → `.rightOf(leftNeighbour)`;
/// 3. Section boundary: the separator to the right of that section → `.leftOf(separator)` (hidden: H,
///    alwaysHidden: AH); separators never disappear.
///
/// When moving back (`destination(in:)`), the first candidate whose anchor is still in the original section is
/// chosen: the anchor's app may have quit, or the anchor may have been moved to another section in the meantime;
/// both cases fall back to the next candidate, and ultimately to the section boundary.
public struct RestorePlan: Hashable, Sendable {
    public let itemID: CGWindowID
    public let section: MenuBarSection
    public let candidates: [MoveDestination]

    public init(itemID: CGWindowID, section: MenuBarSection, candidates: [MoveDestination]) {
        self.itemID = itemID
        self.section = section
        self.candidates = candidates
    }

    /// The section boundary (the last candidate; always present).
    public var boundary: MoveDestination { candidates[candidates.count - 1] }

    /// `layout` is the layout before the item was moved out (while collapsed, so positions are trustworthy).
    /// Returns nil if the item is in the visible section or not in the layout (no move needed).
    public static func make(for itemID: CGWindowID, in layout: MenuBarLayout,
                            controls: FrostControlWindows) -> RestorePlan? {
        for section in [MenuBarSection.hidden, .alwaysHidden] {
            let items = layout[section, default: []]
            guard let index = items.firstIndex(where: { $0.windowID == itemID }) else { continue }
            var candidates: [MoveDestination] = []
            if index + 1 < items.count { candidates.append(.leftOf(items[index + 1].windowID)) }
            if index > 0 { candidates.append(.rightOf(items[index - 1].windowID)) }
            candidates.append(.leftOf(section == .hidden ? controls.hiddenSeparator : controls.alwaysHiddenSeparator))
            return RestorePlan(itemID: itemID, section: section, candidates: candidates)
        }
        return nil
    }

    /// Picks the move-back destination from the current layout: the first candidate whose anchor is still in
    /// `section` (the separator candidate is always available).
    /// Returns the section boundary directly when `layout` is empty (controls not found).
    public func destination(in layout: MenuBarLayout) -> MoveDestination {
        let present = Set(layout[section, default: []].map(\.windowID)).subtracting([itemID])
        return candidates.first { $0 == boundary || present.contains($0.targetWindowID) } ?? boundary
    }
}
