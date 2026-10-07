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

    /// Whether the item is back in its slot in `layout` (a trusted one): in `section`, next to the anchor
    /// `destination(in:)` picks (the last item of the section for the boundary).
    public func isInPlace(in layout: MenuBarLayout) -> Bool {
        let ids = layout[section, default: []].map(\.windowID)
        guard let index = ids.firstIndex(of: itemID) else { return false }
        switch destination(in: layout) {
        case boundary:
            return index == ids.count - 1
        case .leftOf(let anchor):
            return index + 1 < ids.count && ids[index + 1] == anchor
        case .rightOf(let anchor):
            return index > 0 && ids[index - 1] == anchor
        }
    }

    /// The one move that puts the item back into its slot when a move back left it elsewhere (e.g. at the section's
    /// edge after its anchor move failed, or one slot off after the user's click cut the ⌘-drag short): nil when it
    /// is in place, gone (its app quit) or `layout` is unavailable.
    public func correction(in layout: MenuBarLayout) -> MoveDestination? {
        guard !layout.isEmpty, layout.values.joined().contains(where: { $0.windowID == itemID }),
              !isInPlace(in: layout) else { return nil }
        return destination(in: layout)
    }
}
