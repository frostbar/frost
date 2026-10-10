import CoreGraphics

/// The three sections on macOS 27, where they are what the *user arranged* rather than something read from the bar.
///
/// On macOS 26 the sections come from where Frost's separators are (`SectionAssigner`). On 27 paired dividers are
/// aligned with the user's arrangement, but collapsed geometry cannot establish the sections: an icon the bar
/// isn't drawing keeps reporting an old frame, and Apple's `NSStatusItem.occlusionState` no longer reports
/// whether an item is visible either. So the only thing Frost can honestly show is the arrangement it was told
/// (`ItemMemoryStore`), and an icon it was never told about counts as **visible**: assuming it is hidden would be a
/// claim Frost cannot support.
public enum ArrangedLayout {
    /// - Parameters:
    ///   - items: everything the bar reports, Frost's own items included.
    ///   - own: the window IDs of Frost's own items (never part of a section).
    ///   - order: last revealed handles; collapsed AX frames must not reorder known items.
    ///   - remembered: the section the user put an icon in, or nil when Frost was never told.
    /// - Returns: Visible, Hidden and Always Hidden, each in bar order (left to right).
    public static func layout(of items: [MenuBarItem], own: Set<CGWindowID>, order: [CGWindowID] = [],
                              remembered: (MenuBarItem) -> MenuBarSection?) -> MenuBarLayout {
        var layout: MenuBarLayout = [.visible: [], .hidden: [], .alwaysHidden: []]
        let ranks = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        for item in items.sorted(by: {
            let a = ranks[$0.windowID] ?? Int.max, b = ranks[$1.windowID] ?? Int.max
            return a == b ? ($0.frame.minX, $0.windowID) < ($1.frame.minX, $1.windowID) : a < b
        })
        where !own.contains(item.windowID)
            // The bar's overflow chevron is the system's control, not one of the user's icons: it appears and goes
            // with how full the bar is, and without this it would sit at the start of Visible and be picked as the
            // immovable anchor a drop at the end of that section resolves against.
            && !SystemItemRules.isOverflowChevron(bundleID: item.bundleID, axDescription: item.axDescription) {
            layout[remembered(item) ?? .visible, default: []].append(item)
        }
        return layout
    }
}
