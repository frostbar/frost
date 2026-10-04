import Foundation

/// What a click on the Frost icon does in Frost Bar mode.
///
/// Opening can take a moment before the panel is on screen: a previous click forward's item may still be lingering in
/// the Visible section, and the panel waits for it to move back (end the linger, ⌘-drag, settle; measured 0.6–0.9 s).
/// A user who sees nothing happen clicks again; that click must not close (and cancel) an open that isn't visible yet,
/// or the Frost icon seems to ignore clicks. The same goes for a click that lands just after the panel appeared
/// (`reactionGrace`): it was made before the user could see the panel.
public enum FrostBarIconClick {
    public enum Phase: Equatable, Sendable {
        /// The panel is closed.
        case closed
        /// Opening was requested but the panel isn't on screen yet.
        case opening
        /// The panel is on screen since the given instant.
        case presented(at: ContinuousClock.Instant)
    }

    public enum Action: Equatable, Sendable {
        case open(showAlwaysHidden: Bool)
        case close
        /// Ignore the click as a toggle: the panel is (about to be) shown. A non-nil value is a ⌥-click asking to show
        /// the Always Hidden section.
        case keepOpening(showAlwaysHidden: Bool?)
        /// ⌥-click on the shown panel: show / hide the Always Hidden section.
        case setAlwaysHidden(Bool)
    }

    /// Clicks closer than this to the panel's appearance count as made before the user saw it (human reaction time).
    public static let reactionGrace: Duration = .milliseconds(300)

    public static func decide(phase: Phase, option: Bool, showingAlwaysHidden: Bool,
                              now: ContinuousClock.Instant) -> Action {
        switch phase {
        case .closed:
            return .open(showAlwaysHidden: option)
        case .opening:
            return .keepOpening(showAlwaysHidden: option ? true : nil)
        case .presented(let shownAt):
            if now - shownAt < reactionGrace { return .keepOpening(showAlwaysHidden: option ? true : nil) }
            return option ? .setAlwaysHidden(!showingAlwaysHidden) : .close
        }
    }
}

/// Where the Frost icon ends up once a lingering item right of it moves back to its hidden slot.
///
/// A forwarded item lingers directly right of the Frost icon (`.rightOf(icon)`); status items are right-aligned, so when
/// it leaves, the icon and everything left of it slide right by the item's width plus one gap: the icon's right edge
/// lands where the item's right edge was. The Frost Bar opened during the linger is placed under that final position
/// as soon as the item has been dropped, instead of after the ~0.4 s slide (the user would otherwise see nothing for
/// over half a second and click again — at the icon's old place, now another item).
public enum LingerReturnAnchor {
    /// The icon's right edge after `item` leaves, or nil when `item` isn't the icon's right-hand neighbor (any x
    /// coordinate system; only differences matter).
    public static func iconMaxX(icon: CGRect, item: CGRect, maxGap: CGFloat = 16) -> CGFloat? {
        let gap = item.minX - icon.maxX
        guard gap >= -1, gap <= maxGap, item.width > 0 else { return nil }
        return item.maxX
    }
}
