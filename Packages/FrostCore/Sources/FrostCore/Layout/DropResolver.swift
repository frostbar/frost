import CoreGraphics

public enum DropResolver {
    /// - Parameter index: The insertion position in the target section's list with the dragged item removed.
    /// - Returns: The move to perform; nil if the item can't be moved or its position didn't change.
    public static func destination(dragging item: MenuBarItem, to section: MenuBarSection, index: Int,
                                   layout: MenuBarLayout, controls: FrostControlWindows) -> MoveDestination? {
        guard item.isMovable else { return nil }

        let original = layout[section, default: []]
        if let current = original.firstIndex(where: { $0.windowID == item.windowID }), current == index {
            return nil
        }

        let list = original.filter { $0.windowID != item.windowID }
        let movable = list.filter(\.isMovable)
        let clamped = min(max(index, 0), movable.count)

        if clamped < movable.count {
            return .leftOf(movable[clamped].windowID)
        }
        switch section {
        case .alwaysHidden:
            return .leftOf(controls.alwaysHiddenSeparator)
        case .hidden:
            return .leftOf(controls.hiddenSeparator)
        case .visible:
            if let firstImmovable = list.first(where: { !$0.isMovable }) {
                return .leftOf(firstImmovable.windowID)
            }
            if let last = movable.last {
                return .rightOf(last.windowID)
            }
            return .rightOf(controls.icon)
        }
    }
}
