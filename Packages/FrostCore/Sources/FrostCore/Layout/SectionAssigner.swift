import CoreGraphics

/// Window IDs of Frost's own three status items.
public struct FrostControlWindows: Hashable, Sendable {
    public let icon: CGWindowID
    public let hiddenSeparator: CGWindowID
    public let alwaysHiddenSeparator: CGWindowID

    public init(icon: CGWindowID, hiddenSeparator: CGWindowID, alwaysHiddenSeparator: CGWindowID) {
        self.icon = icon
        self.hiddenSeparator = hiddenSeparator
        self.alwaysHiddenSeparator = alwaysHiddenSeparator
    }

    public var all: Set<CGWindowID> { [icon, hiddenSeparator, alwaysHiddenSeparator] }
}

public typealias MenuBarLayout = [MenuBarSection: [MenuBarItem]]

public enum SectionAssigner {
    /// Sorts menu bar items into the three sections, each ordered left to right. Returns an empty dictionary if
    /// the Frost separators can't be found.
    public static func layout(of items: [MenuBarItem], controls: FrostControlWindows) -> MenuBarLayout {
        guard let hidden = items.first(where: { $0.windowID == controls.hiddenSeparator }),
              let alwaysHidden = items.first(where: { $0.windowID == controls.alwaysHiddenSeparator })
        else { return [:] }

        var layout: MenuBarLayout = [.visible: [], .hidden: [], .alwaysHidden: []]
        for item in items.sorted(by: { $0.frame.minX < $1.frame.minX })
        where !controls.all.contains(item.windowID) {
            let x = item.frame.midX
            let section: MenuBarSection =
                x < alwaysHidden.frame.minX ? .alwaysHidden :
                x < hidden.frame.minX ? .hidden : .visible
            layout[section, default: []].append(item)
        }
        return layout
    }
}
