import CoreGraphics

/// The layout the layout editor shows in its "editing" state (all sections expanded).
///
/// On a crowded notched display, items that don't fit after expanding are placed under the notch by the system
/// (`isOnScreen == false`), and where they are placed doesn't necessarily reflect their real order: they may land
/// left of the AH separator, so `SectionAssigner` temporarily classifies them as "always hidden". In the collapsed
/// state the order of items is trustworthy (the separators push the left items out as a block, keeping their
/// order), so the editor takes a snapshot as `previous` before entering editing, and from then on:
///
/// - on-screen items (`isOnScreen`) have trustworthy positions and use the live section and order;
/// - off-screen items already in `previous` have an "unknown position" (on real hardware both their section and
///   their order within the section may be wrong): they stay in their `previous` section and are inserted, in
///   `previous` order, after their nearest predecessor (or first if there is none);
/// - new items not in `previous` use the live section and order.
///
/// When one of Frost's separators is itself off screen (squeezed under the notch while editing), every live section
/// is classified against a separator whose position is not its real one, so no live position is trustworthy: pass
/// `separatorsOnScreen: false` and every item already in `previous` keeps its `previous` section and order (measured
/// on a notched MacBook: the AH separator went under the notch and an always-hidden item to the right of the notch
/// was classified Hidden).
///
/// On every refresh the editor uses the result as the next `previous`; after a successful move, `moving` puts the
/// moved item where the user dropped it.
public enum LayoutReconciler {
    public static func reconcile(live: MenuBarLayout, previous: MenuBarLayout,
                                 separatorsOnScreen: Bool = true) -> MenuBarLayout {
        guard !live.isEmpty, !previous.isEmpty else { return live }

        var previousSection: [CGWindowID: MenuBarSection] = [:]
        for (section, items) in previous {
            for item in items { previousSection[item.windowID] = section }
        }

        var result: MenuBarLayout = [:]
        var overridden: [MenuBarItem] = []
        for section in MenuBarSection.allCases {
            result[section] = []
            for item in live[section, default: []] {
                if !item.isOnScreen || !separatorsOnScreen, previousSection[item.windowID] != nil {
                    overridden.append(item)
                } else {
                    result[section, default: []].append(item)
                }
            }
        }

        // Insert in previous order, so runs of covered items keep their original relative order.
        let previousOrder = MenuBarSection.allCases.flatMap { previous[$0, default: []].map(\.windowID) }
        let rank = Dictionary(previousOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        for item in overridden.sorted(by: { rank[$0.windowID, default: 0] < rank[$1.windowID, default: 0] }) {
            guard let section = previousSection[item.windowID] else { continue }
            let order = previous[section, default: []].map(\.windowID)
            var list = result[section, default: []]
            let position = order.firstIndex(of: item.windowID) ?? 0
            let predecessors = order[..<position].reversed()
            let insertAt = predecessors.lazy
                .compactMap { id in list.firstIndex { $0.windowID == id } }
                .first.map { $0 + 1 } ?? 0
            list.insert(item, at: insertAt)
            result[section] = list
        }
        return result
    }

    /// Moves `id` to `index` in `section` (an index into the list with the moved item removed, consistent with
    /// `InsertionIndex` / `DropResolver`). Returns the layout unchanged if the item isn't found.
    public static func moving(_ id: CGWindowID, to section: MenuBarSection, at index: Int,
                              in layout: MenuBarLayout) -> MenuBarLayout {
        guard let item = layout.values.lazy.flatMap({ $0 }).first(where: { $0.windowID == id }) else { return layout }
        var result = layout.mapValues { $0.filter { $0.windowID != id } }
        var list = result[section, default: []]
        list.insert(item, at: min(max(index, 0), list.count))
        result[section] = list
        return result
    }
}
