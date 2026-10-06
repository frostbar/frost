import AppKit

/// What Frost depends on in the display setup: each display's ID, frame, menu bar height and backing scale.
///
/// `NSApplication.didChangeScreenParametersNotification` also fires when nothing of that changed: AppKit posts it
/// whenever the Dock changes size (an app's tile appears or goes away, a suggested-app tile is inserted), because that
/// changes the screens' `visibleFrame` at the bottom or side. On a real Mac this happened several times an hour, and
/// each one rescanned the menu bar, re-read every app's menu bar items and closed the Frost Bar. Comparing this value
/// before and after lets those notifications be ignored. The menu bar height comes from the top of `visibleFrame`, so a
/// menu bar that starts or stops auto-hiding still counts as a change.
public struct DisplayConfiguration: Equatable, Sendable {
    public struct Display: Equatable, Sendable {
        public let id: CGDirectDisplayID
        /// AppKit frame (bottom-left origin).
        public let frame: CGRect
        public let menuBarHeight: CGFloat
        public let scale: CGFloat

        public init(id: CGDirectDisplayID, frame: CGRect, menuBarHeight: CGFloat, scale: CGFloat) {
            self.id = id
            self.frame = frame
            self.menuBarHeight = menuBarHeight
            self.scale = scale
        }

        /// From a screen's frame and visible frame: only the top of the visible frame (the menu bar) matters.
        public init(id: CGDirectDisplayID, frame: CGRect, visibleFrame: CGRect, scale: CGFloat) {
            self.init(id: id, frame: frame, menuBarHeight: max(0, frame.maxY - visibleFrame.maxY), scale: scale)
        }
    }

    /// Sorted by display ID, so the order the screens are listed in doesn't matter.
    public let displays: [Display]

    public init(displays: [Display]) {
        self.displays = displays.sorted { $0.id < $1.id }
    }

    @MainActor public static var current: DisplayConfiguration {
        DisplayConfiguration(displays: NSScreen.screens.compactMap { screen in
            screen.displayID.map {
                Display(id: $0, frame: screen.frame, visibleFrame: screen.visibleFrame,
                        scale: screen.backingScaleFactor)
            }
        })
    }
}
