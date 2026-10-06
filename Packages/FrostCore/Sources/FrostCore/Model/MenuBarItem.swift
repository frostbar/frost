import CoreGraphics

/// An icon identity that is stable across launches and needs only Accessibility: the real owner's bundle ID + a key
/// derived from the item's AX attributes (`ItemIdentityKey`: its AX identifier, description or help, or its position
/// among the app's items as a last resort). Window titles (the autosave name) need Screen Recording, so they are not
/// part of the identity; they are only an extra signal for migrating data keyed by them (`IdentityMigration`).
///
/// Identities persisted before the AX-based keys existed were bundle ID + window title; they are represented with
/// a `title:` key (`IdentityMigration.legacy(bundleID:title:)`) until they are mapped to the item's current key.
public struct ItemIdentity: Hashable, Codable, Sendable {
    public let bundleID: String
    public let key: String

    public init(bundleID: String, key: String) {
        self.bundleID = bundleID
        self.key = key
    }

    /// Whether this is a pre-AX identity keyed by window title, waiting for `IdentityMigration` to map it.
    public var isLegacy: Bool { key.hasPrefix(IdentityMigration.legacyPrefix) }
}

public struct MenuBarItem: Identifiable, Hashable, Sendable {
    public let windowID: CGWindowID
    /// Global coordinates, top-left origin.
    public let frame: CGRect
    /// From `kCGWindowIsOnscreen`: false for items pushed off screen by a separator or covered by the notch
    /// (visibility can't be judged from geometry alone).
    public let isOnScreen: Bool
    /// The window title (usually the item's autosave name). Empty without Screen Recording permission.
    public let windowTitle: String
    /// The real owner resolved via Accessibility; nil if resolution failed.
    public let bundleID: String?
    public let pid: pid_t?
    /// The item's AX description, or its AX title when it has no description (text items): a display name.
    public let axDescription: String?
    /// The item's AX title: for a text item, the text it shows in the menu bar (may change at any time).
    public let axTitle: String?
    /// The item's AX identifier (system items have one, e.g. `com.apple.menuextra.clock`; most apps' items don't).
    public let axIdentifier: String?
    /// The identity key derived from the owner's AX children (`ItemIdentityKey`); nil while ownership is unresolved.
    public let identityKey: String?
    /// The identity key as versions before number normalization derived it (`ItemIdentityKey.numberedKeys`); nil when
    /// it is the same as `identityKey`. Only used to migrate state remembered under it (`IdentityMigration`).
    public let numberedIdentityKey: String?
    /// One of the two trailing windows of the menu bar, where macOS keeps the clock and the Control Center button
    /// (`SystemItemRules.trailingSlots`). Only used to recognize them when neither an AX identifier nor a title is
    /// known.
    public let occupiesSystemSlot: Bool

    public init(windowID: CGWindowID, frame: CGRect, isOnScreen: Bool, windowTitle: String,
                bundleID: String?, pid: pid_t?, axDescription: String?, axTitle: String? = nil,
                axIdentifier: String? = nil, identityKey: String? = nil, numberedIdentityKey: String? = nil,
                occupiesSystemSlot: Bool = false) {
        self.windowID = windowID
        self.frame = frame
        self.isOnScreen = isOnScreen
        self.windowTitle = windowTitle
        self.bundleID = bundleID
        self.pid = pid
        self.axDescription = axDescription
        self.axTitle = axTitle
        self.axIdentifier = axIdentifier
        self.identityKey = identityKey
        self.numberedIdentityKey = numberedIdentityKey
        self.occupiesSystemSlot = occupiesSystemSlot
    }

    public var id: CGWindowID { windowID }

    /// The same item with a different frame (e.g. a position re-read right before capturing).
    public func with(frame: CGRect) -> MenuBarItem {
        with(frame: frame, isOnScreen: isOnScreen)
    }

    /// The same item with a different frame and on-screen state.
    public func with(frame: CGRect, isOnScreen: Bool) -> MenuBarItem {
        MenuBarItem(windowID: windowID, frame: frame, isOnScreen: isOnScreen, windowTitle: windowTitle,
                    bundleID: bundleID, pid: pid, axDescription: axDescription, axTitle: axTitle,
                    axIdentifier: axIdentifier, identityKey: identityKey, numberedIdentityKey: numberedIdentityKey,
                    occupiesSystemSlot: occupiesSystemSlot)
    }

    /// The stable identity (owner + AX-derived key); nil while the owner is unresolved.
    public var identity: ItemIdentity? {
        guard let bundleID, let identityKey else { return nil }
        return ItemIdentity(bundleID: bundleID, key: identityKey)
    }

    /// Control Center's clock and Control Center button can't be moved by ⌘-dragging (`SystemItemRules`).
    public var isMovable: Bool {
        !SystemItemRules.isFixed(bundleID: bundleID, axIdentifier: axIdentifier, windowTitle: windowTitle,
                                 occupiesSystemSlot: occupiesSystemSlot)
    }
}
