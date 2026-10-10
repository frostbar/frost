/// What Frost can do with the permissions it has. Hiding and showing icons needs none. Accessibility is what the
/// Frost Bar, the layout editor and every move need (owners, identities, clicks, ⌘-drags); Screen Recording is an
/// optional upgrade that only adds real images of the icons (captures, the disk cache, live refresh under a freeze
/// frame). Without it, tiles show the owning app's icon.
public struct PermissionCapabilities: Equatable, Sendable {
    public var accessibility: Bool
    public var screenRecording: Bool
    /// Whether this macOS lets Frost capture icon images at all (`MenuBarBackend`): the window-based backend does,
    /// the macOS 27 one has no per-item windows to capture and its replacement is not implemented yet. The permission
    /// can be granted and still buy nothing, so a grant alone must never start a capture.
    public var capturesSupported: Bool

    public init(accessibility: Bool, screenRecording: Bool, capturesSupported: Bool = true) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.capturesSupported = capturesSupported
    }

    /// The Frost Bar, the layout editor, moving icons (also new-item placement and section memory), click forwarding.
    public var canManageItems: Bool { accessibility }

    /// Capturing images of icons (and reading / writing their disk cache).
    public var canCaptureImages: Bool { screenRecording && capturesSupported }

    /// The Frost Bar's live refresh (temporary expansions under a freeze frame to capture hidden icons): it needs the
    /// Frost Bar and captures.
    public var canLiveRefresh: Bool { canManageItems && canCaptureImages }

    /// Everything works but icons are shown as app-icon tiles: suggest granting Screen Recording for real images.
    /// Never where captures aren't supported at all — there the grant would change nothing, and asking for it would
    /// promise images Frost cannot produce.
    public var suggestsScreenRecording: Bool { canManageItems && !canCaptureImages && capturesSupported }
}

/// How hidden icons are shown when the Frost icon is clicked (the user's setting).
public enum DisplayMode: String, CaseIterable, Sendable {
    /// Frost Bar on displays with a notch, in-place expansion elsewhere.
    case automatic
    /// Expand hidden icons in place in the menu bar.
    case inline
    /// Show hidden icons in the Frost Bar panel below the menu bar.
    case frostBar

    /// The mode in effect on a display: in place when the Frost Bar isn't available (it needs Accessibility, not
    /// Screen Recording); `.automatic` uses the Frost Bar on displays with a notch, in place elsewhere.
    public func effective(hasNotch: Bool, capabilities: PermissionCapabilities) -> DisplayMode {
        guard capabilities.canManageItems else { return .inline }
        switch self {
        case .automatic: return hasNotch ? .frostBar : .inline
        case .inline, .frostBar: return self
        }
    }
}
