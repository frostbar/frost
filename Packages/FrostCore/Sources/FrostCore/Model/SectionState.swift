/// How far the menu bar is expanded (`SectionController` in the app layer applies it to the separators).
public enum SectionState: Int, Comparable, Sendable {
    /// Hidden and Always Hidden items are pushed off screen.
    case collapsed
    /// Hidden items are shown in the menu bar.
    case expanded
    /// Hidden and Always Hidden items are shown in the menu bar.
    case expandedAll

    public static func < (lhs: SectionState, rhs: SectionState) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The state a click on the Frost icon asks for when it expands in the menu bar (not the Frost Bar): a click
    /// toggles collapsed ↔ expanded; with ⌥ it expands everything (or collapses when everything is shown).
    public func afterIconClick(option: Bool) -> SectionState {
        switch (self, option) {
        case (.collapsed, false): .expanded
        case (.collapsed, true), (.expanded, true): .expandedAll
        case (.expanded, false), (.expandedAll, _): .collapsed
        }
    }
}

/// A temporary expansion in progress (the Frost Bar's live refresh expands the menu bar under a freeze frame for a
/// fraction of a second, then restores it).
///
/// While it lasts, the menu bar's real state is the temporary one, but the user still sees (under the freeze frame)
/// and reasons about the state from before it: state changes requested meanwhile (a click on the Frost icon, ⌥-click)
/// are judged against `userState` and recorded, and the restore ends in `finalState` instead of blindly going back to
/// `prior` (which would lose the click or undo it).
public struct TemporaryExpansion: Equatable, Sendable {
    /// The state before the temporary expansion.
    public let prior: SectionState
    /// The last state requested while the expansion lasted (nil = none).
    public private(set) var requested: SectionState?

    public init(prior: SectionState) {
        self.prior = prior
    }

    /// The state as the user knows it: what they last asked for, or the state before the expansion.
    public var userState: SectionState { requested ?? prior }

    /// The state the restore must end in.
    public var finalState: SectionState { userState }

    /// Records a state change requested while the expansion lasts.
    public mutating func request(_ state: SectionState) {
        requested = state
    }

    /// Records a click on the Frost icon (inline display mode), judged against `userState`.
    public mutating func iconClicked(option: Bool) {
        request(userState.afterIconClick(option: option))
    }
}
