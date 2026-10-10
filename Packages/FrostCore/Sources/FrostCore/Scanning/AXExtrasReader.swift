import AppKit
import ApplicationServices

public enum AXExtrasReader {
    /// An app to read (collected from `NSWorkspace` on the main thread, then handed to the background read).
    public struct RunningApp: Hashable, Sendable {
        public let pid: pid_t
        public let bundleID: String

        public init(pid: pid_t, bundleID: String) {
            self.pid = pid
            self.bundleID = bundleID
        }
    }

    /// Reads the menu bar extras (status items) of all running apps in the background, off the main thread: a
    /// single hung app uses up the full 0.25 s AX timeout, and reading everything takes about 300 ms. Requires
    /// Accessibility permission; returns an empty array without it.
    @MainActor
    public static func readAllInBackground() async -> [AXItemInfo] {
        guard AXIsProcessTrusted() else { return [] }
        let apps = runningApps()
        return await Task.detached(priority: .userInitiated) { readAll(apps) }.value
    }

    /// Running apps with a bundle ID, skipping this process: AX messages sent to yourself short-circuit in-process
    /// on the calling thread (on the main thread they may wait out the full timeout). Frost's own items get their
    /// ownership directly from `MenuBarItemScanner.ownWindowIDs`.
    @MainActor
    public static func runningApps() -> [RunningApp] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.processIdentifier != ownPID, let bundleID = app.bundleIdentifier else { return nil }
            return RunningApp(pid: app.processIdentifier, bundleID: bundleID)
        }
    }

    /// Synchronously reads the menu bar extras of `apps`. Callable from any thread (blocks the calling thread);
    /// don't call it on the main thread.
    public static func readAll(_ apps: [RunningApp]) -> [AXItemInfo] {
        guard AXIsProcessTrusted() else { return [] }
        var result: [AXItemInfo] = []
        for app in apps {
            let element = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            guard let bar: AXUIElement = copy(element, kAXExtrasMenuBarAttribute),
                  let children: [AXUIElement] = copy(extrasBar(bar), kAXChildrenAttribute) else { continue }
            // Every child's identifying attributes first (zero-size ones too): identity keys depend on the app's whole
            // list of extras (`ItemIdentityKey`).
            let read = children.map { child in
                AXUIElementSetMessagingTimeout(child, messagingTimeout)
                let description: String? = copy(child, kAXDescriptionAttribute)
                let title: String? = copy(child, kAXTitleAttribute)
                let attributes = AXItemAttributes(identifier: copy(child, kAXIdentifierAttribute),
                                                  description: description, help: copy(child, kAXHelpAttribute))
                return (frame: frame(of: child), description: description, title: title, attributes: attributes)
            }
            let keys = ItemIdentityKey.keys(for: read.map(\.attributes))
            let numberedKeys = ItemIdentityKey.numberedKeys(for: read.map(\.attributes))
            for (child, (key, numberedKey)) in zip(read, zip(keys, numberedKeys)) {
                guard let frame = child.frame else { continue }
                // Icon items usually describe themselves; text items (no image) often have only a title.
                let description = (child.description?.isEmpty ?? true) ? child.title : child.description
                result.append(AXItemInfo(bundleID: app.bundleID, pid: app.pid, frame: frame, description: description,
                                         title: child.title, identifier: child.attributes.identifier,
                                         identityKey: key,
                                         numberedIdentityKey: numberedKey == key ? nil : numberedKey))
            }
        }
        return result
    }

    /// Finds the AX element matching the given frame (for AXPress), using the same matching rule as ownership
    /// merging; returns nil if there is no eligible candidate. Callable from any thread (ItemClicker calls it on a
    /// background thread so a hung target app doesn't block the main thread).
    public static func element(pid: pid_t, matching frame: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let bar: AXUIElement = copy(app, kAXExtrasMenuBarAttribute),
              let children: [AXUIElement] = copy(extrasBar(bar), kAXChildrenAttribute) else { return nil }
        let frames = children.map { child in
            AXUIElementSetMessagingTimeout(child, messagingTimeout)
            return self.frame(of: child) ?? .zero
        }
        return AXItemMatcher.bestMatch(for: frame, among: frames).map { children[$0] }
    }

    /// Finds the AX element of the extra whose identity key is `identityKey` (`ItemIdentityKey`).
    ///
    /// On macOS 27 a menu bar item that the bar isn't drawing keeps reporting its previous frame, so matching by
    /// frame (`element(pid:matching:)`) can find a *different* item that now sits there. The identity, derived from
    /// the app's whole list of extras, does not move. Callable from any thread.
    public static func element(pid: pid_t, identityKey: String) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let bar: AXUIElement = copy(app, kAXExtrasMenuBarAttribute),
              let children: [AXUIElement] = copy(extrasBar(bar), kAXChildrenAttribute) else { return nil }
        let attributes = children.map { child -> AXItemAttributes in
            AXUIElementSetMessagingTimeout(child, messagingTimeout)
            return AXItemAttributes(identifier: copy(child, kAXIdentifierAttribute),
                                    description: copy(child, kAXDescriptionAttribute),
                                    help: copy(child, kAXHelpAttribute))
        }
        let keys = ItemIdentityKey.keys(for: attributes)
        guard let index = keys.firstIndex(of: identityKey) else { return nil }
        return children[index]
    }

    /// Whether the menu bar item with `identityKey` of `pid` really is the thing drawn at `point` (CG global
    /// coordinates) — the check that has to pass before Frost posts a synthesized ⌘ mouse-down there.
    ///
    /// A ⌘-drag on macOS 27 starts on the item itself, and an item the bar isn't drawing keeps reporting the frame it
    /// had before it left: posting at that frame would press whatever *is* there, which may be another app's item.
    /// So the item is resolved by identity first (`element(pid:identityKey:)`), and the element the system reports at
    /// the point has to be that element — or one of its descendants, since the extras element usually contains the
    /// button that is actually drawn. Anything that cannot be established returns false (the caller then posts
    /// nothing); a check that fails open would be worse than no check.
    public static func isItemAt(_ point: CGPoint, pid: pid_t, identityKey: String) -> Bool {
        guard let expected = element(pid: pid, identityKey: identityKey) else { return false }
        var hit: AXUIElement?
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return false }
        for _ in 0..<maximumHitTestDepth {
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            if CFEqual(element, expected) { return true }
            guard let parent: AXUIElement = copy(element, kAXParentAttribute) else { return false }
            element = parent
        }
        return false
    }

    /// The process that owns the element the system reports at `point`, or nil when it can't be read. Used for
    /// Frost's own status items, whose Accessibility labels are localized ("Frost Separator") rather than identifying:
    /// the point is over one of them exactly when the system reports a Frost element there.
    public static func processAt(_ point: CGPoint) -> pid_t? {
        var hit: AXUIElement?
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let element = hit else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    /// How far up from the element the system reports at a point Frost looks for the extras element itself (the
    /// extras element contains the button, which may contain a view, …).
    static let maximumHitTestDepth = 8

    /// Messaging timeout for every element read here. A timeout set on an element applies to that element only (not to
    /// elements obtained from it), so it is set on the app, the extras bar and each child: without it, a hung app
    /// blocks each read for the system default (about 6 s) instead of 0.25 s.
    static let messagingTimeout: Float = 0.25

    /// Applies `messagingTimeout` to the extras bar element and returns it.
    static func extrasBar(_ bar: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(bar, messagingTimeout)
        return bar
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: AXValue = copy(element, kAXPositionAttribute),
              let size: AXValue = copy(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position, .cgPoint, &point)
        AXValueGetValue(size, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
