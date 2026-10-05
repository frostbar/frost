import CoreGraphics
import Foundation

/// Remembers the section the user keeps each icon in (by `ItemIdentity`) and puts icons back there when the system
/// re-adds them elsewhere.
///
/// An app whose status item has no stable autosave name (or whose saved position is lost) gets its icon re-added at the
/// far left of all status items when it relaunches, i.e. in the Always Hidden section. Frost knows the icon's identity,
/// so when a window it hasn't seen during this run shows up in a section other than the remembered one, it is moved
/// back (`restores`).
///
/// - **Memory** (`memory`, persisted): identity → section. Written when the user moves an icon (an editor drop via
///   `record`, or a ⌘-drag in the menu bar detected by `observe`: the **same window** changed section without Frost
///   moving it), when Frost places a new icon (`record`), and seeded from the first trusted observation of an identity
///   that has no entry yet (existing entries are never overwritten by seeding), unless that identity may still take
///   over a title-keyed entry (`awaitingMigration`).
/// - **This run** (`observed`, `unsettled`): the section each window was last seen in, and the windows not yet checked
///   against the memory. A window is checked once, when it first appears (an app launch or relaunch, the item being
///   re-created, or Frost's own launch); after that only the user moves it, and a section change of a known window
///   updates the memory instead of being reverted (never fight the user).
/// - **Trust**: `observe` must only be called with a layout whose sections are reliable (not editing, no move
///   transaction in progress, no mouse button held, neither separator under the notch). Items under the notch
///   (`obscured`) are skipped. Windows Frost itself moved since the last observation (`movedByFrost`) only update
///   `observed`: Frost records its intentional moves explicitly, and a temporary move it couldn't undo (a Frost Bar
///   move-back that failed) must not be mistaken for the user's choice.
/// - **Ambiguity**: when several current items share an identity (e.g. an app's item re-created while the old window
///   lingers), that identity is neither recorded nor restored, and windows with it stay unchecked until it is unique.
/// - Unresolved items (no owner yet) wait until they resolve.
public struct SectionKeeper: Equatable, Sendable {
    /// identity → the section the user keeps that icon in.
    public private(set) var memory: [ItemIdentity: MenuBarSection]
    /// The section each window was last seen in during this run.
    public private(set) var observed: [CGWindowID: MenuBarSection] = [:]
    /// Windows seen during this run but not yet checked against `memory` (a restore is pending or not possible yet).
    public private(set) var unsettled: Set<CGWindowID> = []

    public init(memory: [ItemIdentity: MenuBarSection] = [:]) {
        self.memory = memory
    }

    /// A window to move back into its remembered section.
    public struct Restore: Equatable, Sendable {
        public let item: MenuBarItem
        public let identity: ItemIdentity
        public let from: MenuBarSection
        public let to: MenuBarSection

        public init(item: MenuBarItem, identity: ItemIdentity, from: MenuBarSection, to: MenuBarSection) {
            self.item = item
            self.identity = identity
            self.from = from
            self.to = to
        }
    }

    /// A section change of a known window that Frost didn't make: the user's own move.
    public struct UserMove: Equatable, Sendable {
        public let identity: ItemIdentity
        public let from: MenuBarSection
        public let to: MenuBarSection

        public init(identity: ItemIdentity, from: MenuBarSection, to: MenuBarSection) {
            self.identity = identity
            self.from = from
            self.to = to
        }
    }

    public struct Outcome: Equatable, Sendable {
        /// Windows to move back (left to right); the caller reports each attempt with `restoreAttempted`.
        public var restores: [Restore] = []
        /// Moves the user made (already written to `memory`).
        public var userMoves: [UserMove] = []
        /// Identities seeded into `memory` (they had no entry).
        public var seeded: Set<ItemIdentity> = []
        /// Identities shared by several current items (skipped).
        public var ambiguous: Set<ItemIdentity> = []

        public var memoryChanged: Bool { !userMoves.isEmpty || !seeded.isEmpty }
    }

    /// Processes a trusted layout (see the type's documentation).
    ///
    /// - Parameters:
    ///   - obscured: items whose position can't be trusted (under the notch): skipped.
    ///   - movedByFrost: windows Frost moved since the last observation.
    ///   - skipping: windows another placement (new items) is moving right now: left unseen this time.
    ///   - restoreEnabled: the user's setting; when off, displaced windows are accepted where they are.
    ///   - canMove: moving is possible now (collapsed, user present, …); when false, displaced windows stay unchecked
    ///     until it is.
    ///   - awaitingMigration: identities that may still take over a remembered legacy identity
    ///     (`IdentityMigration.awaitingMigration`): not seeded (the window stays unchecked), so the migration can still
    ///     bring back the section the user chose. A move the user makes is still recorded.
    public mutating func observe(layout: MenuBarLayout, obscured: Set<CGWindowID> = [],
                                 movedByFrost: Set<CGWindowID> = [], skipping: Set<CGWindowID> = [],
                                 awaitingMigration: Set<ItemIdentity> = [],
                                 restoreEnabled: Bool, canMove: Bool) -> Outcome {
        var outcome = Outcome()
        let entries = MenuBarSection.leftToRight.flatMap { section in
            layout[section, default: []].map { (item: $0, section: section) }
        }
        let present = Set(entries.map(\.item.windowID))
        observed = observed.filter { present.contains($0.key) }
        unsettled.formIntersection(present)

        let identities = entries.compactMap { NewItemPlacement.identity(of: $0.item) }
        let counts = Dictionary(identities.map { ($0, 1) }, uniquingKeysWith: +)

        for (item, section) in entries {
            let id = item.windowID
            guard !obscured.contains(id), !skipping.contains(id),
                  let identity = NewItemPlacement.identity(of: item) else { continue }
            let previous = observed[id]
            if counts[identity, default: 0] > 1 {
                outcome.ambiguous.insert(identity)
                // Known windows keep tracking their section; new ones stay unseen until the identity is unique.
                if previous != nil { observed[id] = section }
                continue
            }
            guard item.isMovable else {
                observed[id] = section
                unsettled.remove(id)
                continue
            }
            if let previous, previous != section {
                observed[id] = section
                if movedByFrost.contains(id) { continue }
                // The same window changed section without Frost moving it: the user did (also when it was still
                // waiting to be checked: it is where they want it now).
                unsettled.remove(id)
                outcome.userMoves.append(UserMove(identity: identity, from: previous, to: section))
                memory[identity] = section
                continue
            }
            if previous == nil {
                observed[id] = section
                unsettled.insert(id)
            }
            guard unsettled.contains(id) else { continue }
            guard let remembered = memory[identity] else {
                if awaitingMigration.contains(identity) { continue }
                memory[identity] = section
                outcome.seeded.insert(identity)
                unsettled.remove(id)
                continue
            }
            if remembered == section || !restoreEnabled {
                unsettled.remove(id)
            } else if canMove {
                outcome.restores.append(Restore(item: item, identity: identity, from: section, to: remembered))
            }
        }
        return outcome
    }

    /// A restore was attempted (moved or failed): the window is checked and not retried.
    public mutating func restoreAttempted(_ windowID: CGWindowID) {
        unsettled.remove(windowID)
    }

    /// Records that `item` now belongs to `section` (the user dropped it there in the layout editor, or Frost placed a
    /// new icon there). Returns false (nothing recorded) when its identity is unresolved or shared by several of
    /// `items` (the current menu bar items).
    @discardableResult
    public mutating func record(_ item: MenuBarItem, in section: MenuBarSection, among items: [MenuBarItem]) -> Bool {
        guard let identity = NewItemPlacement.identity(of: item),
              items.filter({ NewItemPlacement.identity(of: $0) == identity }).count <= 1 else { return false }
        memory[identity] = section
        return true
    }

    /// Where a restored icon goes: the section's boundary, like the layout editor's drop at the end of Hidden / Always
    /// Hidden (`.leftOf` the section's separator); Visible goes right of the Frost icon, where the Frost Bar moves icons
    /// it clicks.
    public static func destination(for section: MenuBarSection, controls: FrostControlWindows) -> MoveDestination {
        switch section {
        case .alwaysHidden: .leftOf(controls.alwaysHiddenSeparator)
        case .hidden: .leftOf(controls.hiddenSeparator)
        case .visible: .rightOf(controls.icon)
        }
    }

    /// Whether one of Frost's separators sits where the section boundaries say it does. A narrow separator (expanded,
    /// 16 or 1 pt) squeezed under the notch is `onscreen=false` inside the display and its x is not its real position
    /// (`ItemMover.isObscured`). A pushed-out separator (5016 pt wide while collapsed) is `onscreen=false` too, but the
    /// order is always preserved (spike-findings.md), so it is reliable.
    public static func separatorIsReliable(_ separator: MenuBarItem, displayBounds: CGRect) -> Bool {
        separator.frame.width >= pushedOutMinWidth || !ItemMover.isObscured(separator, displayBounds: displayBounds)
    }

    /// Narrower than any pushed-out separator (5016 pt), wider than any other status item.
    static let pushedOutMinWidth: CGFloat = 1000

    // MARK: - Persistence

    /// Moves remembered sections to the identities `plan` maps them to (`IdentityMigration`). Returns whether the
    /// memory changed.
    @discardableResult
    public mutating func rekey(_ plan: [ItemIdentity: ItemIdentity]) -> Bool {
        let updated = IdentityMigration.apply(plan, to: memory)
        guard updated != memory else { return false }
        memory = updated
        return true
    }

    private struct Entry: Codable {
        var bundleID: String
        var key: String
        var section: MenuBarSection
    }

    private struct LegacyEntry: Codable {
        var bundleID: String
        var title: String
        var section: MenuBarSection
    }

    /// Persistence format (version 2): a JSON array of `{bundleID, key, section}` sorted by bundleID, then key (stable
    /// contents). The key it is stored under carries the format version.
    public static func encode(_ memory: [ItemIdentity: MenuBarSection]) throws -> Data {
        let entries = memory
            .map { Entry(bundleID: $0.key.bundleID, key: $0.key.key, section: $0.value) }
            .sorted { ($0.bundleID, $0.key) < ($1.bundleID, $1.key) }
        return try JSONEncoder().encode(entries)
    }

    public static func decode(_ data: Data) throws -> [ItemIdentity: MenuBarSection] {
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        return Dictionary(entries.map { (ItemIdentity(bundleID: $0.bundleID, key: $0.key), $0.section) },
                          uniquingKeysWith: { _, last in last })
    }

    /// Reads version 1 (`{bundleID, title, section}`, keyed by window title) as legacy identities
    /// (`IdentityMigration.legacy`), which `IdentityMigration` maps to the items' current identities.
    public static func decodeLegacy(_ data: Data) throws -> [ItemIdentity: MenuBarSection] {
        let entries = try JSONDecoder().decode([LegacyEntry].self, from: data)
        return Dictionary(entries.map {
            (IdentityMigration.legacy(bundleID: $0.bundleID, title: $0.title), $0.section)
        }, uniquingKeysWith: { _, last in last })
    }
}
