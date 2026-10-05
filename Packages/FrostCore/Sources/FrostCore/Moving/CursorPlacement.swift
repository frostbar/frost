import CoreGraphics

/// Where the pointer ends up after a synthesized ⌘-drag (`ItemMover.move(_:to:until:cursor:)`).
public enum CursorDisposition: Sendable, Equatable {
    /// A background move (the move back after a linger, layout editor drops, the section keeper, new-item placement):
    /// the pointer goes back exactly where the user left it, right after the mouse-up, hidden meanwhile.
    case restore
    /// The Frost Bar's move out for a forwarded click: the pointer stays hidden until the item has landed and then
    /// appears on the item's centre, so it visibly moves once (from the tile to the item) and rests on the menu bar,
    /// which keeps the linger alive (`ForwardLinger`) until the user moves away.
    case onMovedItem
}

/// Pure decisions about the pointer around synthesized events (unit tested); `CursorConcealment` does the hiding.
public enum CursorPlacement {
    /// Whether the drag itself puts the pointer back (and shows it) right after its mouse-up: true for background
    /// moves, so the pointer is away for as short a time as possible. A move out keeps it hidden until the item lands.
    public static func restoresRightAfterDrag(_ disposition: CursorDisposition) -> Bool {
        disposition == .restore
    }

    /// Where to put the pointer once a move is over. `landedItemFrame`: the moved item's final frame, nil when the move
    /// didn't take effect (failed, cancelled, retrying). A move out that didn't land on screen (or on `displayBounds`)
    /// goes back to `saved` too: the user's pointer is never left somewhere unrelated. nil: leave the pointer alone.
    public static func finalPosition(_ disposition: CursorDisposition, saved: CGPoint?, landedItemFrame: CGRect?,
                                     displayBounds: CGRect? = nil) -> CGPoint? {
        switch disposition {
        case .restore:
            return saved
        case .onMovedItem:
            guard let frame = landedItemFrame else { return saved }
            let centre = CGPoint(x: frame.midX, y: frame.midY)
            if let displayBounds, !displayBounds.contains(centre) { return saved }
            return centre
        }
    }

    /// Before a forwarded click: the point to move the pointer to (the item's centre), or nil when it is already
    /// there (within `tolerance`), e.g. because the move out left it on the item.
    public static func restingPoint(forClickOn itemFrame: CGRect, cursor: CGPoint?,
                                    tolerance: CGFloat = 0.5) -> CGPoint? {
        let centre = CGPoint(x: itemFrame.midX, y: itemFrame.midY)
        guard let cursor else { return centre }
        return isNear(cursor, centre, tolerance: tolerance) ? nil : centre
    }

    /// Whether a synthesized click at `point` (which warps the pointer there and back) should hide the pointer:
    /// only when the pointer is somewhere else; a click where the pointer already rests must not make it blink.
    public static func hidesDuringClick(at point: CGPoint, cursor: CGPoint?, tolerance: CGFloat = 0.5) -> Bool {
        guard let cursor else { return false }
        return !isNear(cursor, point, tolerance: tolerance)
    }

    static func isNear(_ a: CGPoint, _ b: CGPoint, tolerance: CGFloat) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }
}
