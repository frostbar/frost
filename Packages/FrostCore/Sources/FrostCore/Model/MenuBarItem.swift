import CoreGraphics

/// An icon identity that is stable across launches: the real owner's bundle ID + window title (usually the icon's autosave name).
public struct ItemIdentity: Hashable, Codable, Sendable {
    public let bundleID: String
    public let title: String

    public init(bundleID: String, title: String) {
        self.bundleID = bundleID
        self.title = title
    }
}

public struct MenuBarItem: Identifiable, Hashable, Sendable {
    public let windowID: CGWindowID
    /// Global coordinates, top-left origin.
    public let frame: CGRect
    /// From `kCGWindowIsOnscreen`: false for items pushed off screen by a separator or covered by the notch
    /// (visibility can't be judged from geometry alone).
    public let isOnScreen: Bool
    public let windowTitle: String
    /// The real owner resolved via Accessibility; nil if resolution failed.
    public let bundleID: String?
    public let pid: pid_t?
    public let axDescription: String?

    public init(windowID: CGWindowID, frame: CGRect, isOnScreen: Bool, windowTitle: String,
                bundleID: String?, pid: pid_t?, axDescription: String?) {
        self.windowID = windowID
        self.frame = frame
        self.isOnScreen = isOnScreen
        self.windowTitle = windowTitle
        self.bundleID = bundleID
        self.pid = pid
        self.axDescription = axDescription
    }

    public var id: CGWindowID { windowID }

    /// The same item with a different frame (e.g. a position re-read right before capturing).
    public func with(frame: CGRect) -> MenuBarItem {
        MenuBarItem(windowID: windowID, frame: frame, isOnScreen: isOnScreen, windowTitle: windowTitle,
                    bundleID: bundleID, pid: pid, axDescription: axDescription)
    }

    public var identity: ItemIdentity {
        ItemIdentity(bundleID: bundleID ?? "unknown", title: windowTitle)
    }

    /// Control Center's clock and Control Center button can't be moved by ⌘-dragging. With unresolved ownership
    /// (nil), decides conservatively by title.
    public var isMovable: Bool {
        guard bundleID == "com.apple.controlcenter" || bundleID == nil else { return true }
        return !(windowTitle == "Clock" || windowTitle.hasPrefix("BentoBox"))
    }
}
