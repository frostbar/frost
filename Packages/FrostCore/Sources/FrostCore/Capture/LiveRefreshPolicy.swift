import CoreGraphics

/// Cadence and pause rules for "live refresh" of hidden items' captures while Frost Bar is open.
///
/// While collapsed, hidden items are off screen and cannot be captured (ScreenCaptureKit −3811), so captures of
/// dynamic icons (temperature, fan speed, timers…) go stale. While the panel is open, a loop runs at a fixed cadence:
/// a freeze frame covers the part of the menu bar that will change → temporary expand → capture one menu bar strip
/// and crop each item → collapse → remove the freeze frame (see the app layer's `FrostBarController`). Only the pure
/// logic lives here:
///
/// - Cadence: `period` (1 s) start to start; when a cycle overruns, the next one starts at least `minimumGap` after
///   the previous one ended.
/// - Pausing: any situation where "expanding now would disturb the user or conflict with another operation" skips
///   the cycle (`skipReason`), re-evaluated after `pausedRecheck`.
public enum LiveRefreshPolicy {
    /// Interval between the starts of two cycles (start to start).
    public static let period: Duration = .seconds(1)
    /// Minimum interval from the end of one cycle to the start of the next (applies when a cycle exceeds `period`).
    public static let minimumGap: Duration = .milliseconds(200)
    /// How often to re-evaluate while paused.
    public static let pausedRecheck: Duration = .milliseconds(250)

    /// The panel's appearance animation (0.18 s fade in + slide down, `FrostBarController.present`) plus a margin.
    /// The freeze frame captures the menu bar as it is at that moment, including the panel's shadow that reaches
    /// into the menu bar; captured before the animation ends, the shadow in the freeze frame is fainter than the real
    /// one and visibly jumps when the freeze frame is removed.
    public static let appearanceDuration: Duration = .milliseconds(250)

    /// How long to wait before the next cycle starts. `sinceLastStart` / `sinceLastEnd` of nil means there was no
    /// previous cycle (the first cycle after the panel opens, or when an ⌥ toggle / refresh requests an immediate
    /// cycle that is not bound by `period`). `sincePresented`: how long the panel has been shown (nil = ignore);
    /// no cycle starts before the appearance animation ends (`appearanceDuration`).
    public static func delayBeforeNextCycle(sinceLastStart: Duration?, sinceLastEnd: Duration?,
                                            sincePresented: Duration? = nil) -> Duration {
        var delay: Duration = .zero
        if let sinceLastStart { delay = max(delay, period - sinceLastStart) }
        if let sinceLastEnd { delay = max(delay, minimumGap - sinceLastEnd) }
        if let sincePresented { delay = max(delay, appearanceDuration - sincePresented) }
        return delay
    }

    /// All the conditions that decide whether this cycle can run (collected by the app layer every cycle).
    public struct Conditions: Equatable, Sendable {
        public var isPanelOpen: Bool
        /// Accessibility + Screen Recording.
        public var hasPermissions: Bool
        /// Frost Bar's click forwarding (move out → click → wait for the presentation to close → move back) has not
        /// finished yet.
        public var isActivationInFlight: Bool
        /// An `ItemMover` transaction is in progress (editor drag and drop, new item placement, move-back retry…).
        public var isMoveInFlight: Bool
        /// A mouse button is held (`NSEvent.pressedMouseButtons != 0`): the user may be dragging or clicking.
        public var isMouseButtonPressed: Bool
        /// A menu is on screen (layer 101, any app).
        public var isMenuOnScreen: Bool
        /// A presentation (popover etc.) opened by the last forwarded click is still on screen after the wait timed
        /// out / was abandoned.
        public var isForwardedPresentationOnScreen: Bool
        /// The layout editor is in editing mode.
        public var isEditing: Bool
        /// The section state machine is collapsed (no temporary expand while the user has expanded in place).
        public var isCollapsed: Bool
        /// The pointer is over the part of the menu bar that changes on expand (see `isPointerInChangingRegion`):
        /// a click now would land on the real, expanded items.
        public var isPointerOverChangingMenuBar: Bool
        /// There are items worth expanding for (the panel has items, and not all of them are items that still cannot
        /// be captured after expanding; see `CaptureRetryPolicy`).
        public var hasCapturableItems: Bool

        public init(isPanelOpen: Bool = true, hasPermissions: Bool = true, isActivationInFlight: Bool = false,
                    isMoveInFlight: Bool = false, isMouseButtonPressed: Bool = false, isMenuOnScreen: Bool = false,
                    isForwardedPresentationOnScreen: Bool = false, isEditing: Bool = false,
                    isCollapsed: Bool = true, isPointerOverChangingMenuBar: Bool = false,
                    hasCapturableItems: Bool = true) {
            self.isPanelOpen = isPanelOpen
            self.hasPermissions = hasPermissions
            self.isActivationInFlight = isActivationInFlight
            self.isMoveInFlight = isMoveInFlight
            self.isMouseButtonPressed = isMouseButtonPressed
            self.isMenuOnScreen = isMenuOnScreen
            self.isForwardedPresentationOnScreen = isForwardedPresentationOnScreen
            self.isEditing = isEditing
            self.isCollapsed = isCollapsed
            self.isPointerOverChangingMenuBar = isPointerOverChangingMenuBar
            self.hasCapturableItems = hasCapturableItems
        }
    }

    /// Why this cycle is skipped (in priority order; the first that holds).
    public enum SkipReason: String, Sendable, CaseIterable {
        case panelClosed, permissionsMissing, activation, move, editing, notCollapsed, mouseDown, menuOpen,
             presentationOpen, pointerInMenuBar, nothingToCapture
    }

    /// nil = the cycle may run.
    public static func skipReason(_ c: Conditions) -> SkipReason? {
        if !c.isPanelOpen { return .panelClosed }
        if !c.hasPermissions { return .permissionsMissing }
        if c.isActivationInFlight { return .activation }
        if c.isMoveInFlight { return .move }
        if c.isEditing { return .editing }
        if !c.isCollapsed { return .notCollapsed }
        if c.isMouseButtonPressed { return .mouseDown }
        if c.isMenuOnScreen { return .menuOpen }
        if c.isForwardedPresentationOnScreen { return .presentationOpen }
        if c.isPointerOverChangingMenuBar { return .pointerInMenuBar }
        if !c.hasCapturableItems { return .nothingToCapture }
        return nil
    }

    /// Whether a cycle in progress (freeze frame shown) should continue: it ends immediately (no capture, collapse
    /// right away) when the panel closes (including a click on one of its icons), a mouse button is pressed, or the
    /// pointer moves into the changing part of the menu bar.
    public static func shouldAbortCycle(isPanelOpen: Bool, isMouseButtonPressed: Bool,
                                        isPointerOverChangingMenuBar: Bool) -> Bool {
        !isPanelOpen || isMouseButtonPressed || isPointerOverChangingMenuBar
    }

    /// The part of a menu bar strip that changes on expand / collapse (same coordinate space as the arguments,
    /// usually AppKit global coordinates).
    ///
    /// Expanding only changes what is to the **left** of the Frost icon: the separator is left of the icon, and the
    /// positions of the icon and everything to its right (clock, Control Center…) are determined by the items on the
    /// right and are unaffected. So the strip containing the icon only needs to be covered left of the icon; the right
    /// side stays live (the clock keeps ticking). `iconFrames` holds the Frost icon on each display (the real window
    /// on the active menu bar + replicas on other displays, see `MenuBarDisplayResolver`); the one lying in this strip
    /// is used. If none lies in this strip (replica position unknown), the whole strip is covered.
    public static func changingRegion(of strip: CGRect, iconFrames: [CGRect]) -> CGRect {
        guard let iconFrame = iconFrames.first(where: { icon in
            strip.minX <= icon.midX && icon.midX < strip.maxX && strip.minY <= icon.midY && icon.midY <= strip.maxY
        }) else { return strip }
        var region = strip
        region.size.width = max(0, iconFrame.minX - strip.minX)
        return region
    }

    /// `changingRegion(of:iconFrames:)` when only one icon is known (usually the real window).
    public static func changingRegion(of strip: CGRect, iconFrame: CGRect?) -> CGRect {
        changingRegion(of: strip, iconFrames: iconFrame.map { [$0] } ?? [])
    }

    /// Rounds the four edges of a freeze frame region (points) to the nearest device pixel (`scale` is the screen's
    /// backingScaleFactor): the window's and the capture's pixel sizes then match exactly and the capture is shown
    /// 1:1, unscaled (scaling blurs glyphs, which is noticeable when the freeze frame appears / disappears).
    public static func pixelAligned(_ rect: CGRect, scale: CGFloat) -> CGRect {
        guard scale > 0 else { return rect }
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let minX = snap(rect.minX), minY = snap(rect.minY)
        return CGRect(x: minX, y: minY, width: snap(rect.maxX) - minX, height: snap(rect.maxY) - minY)
    }

    /// Whether the pointer (same coordinate space as `strips`) is over the changing part of any menu bar strip
    /// (`iconFrames` as in `changingRegion`).
    public static func isPointerInChangingRegion(_ pointer: CGPoint, strips: [CGRect], iconFrames: [CGRect]) -> Bool {
        strips.contains { strip in
            let region = changingRegion(of: strip, iconFrames: iconFrames)
            return pointer.x >= region.minX && pointer.x < region.maxX
                && pointer.y >= region.minY && pointer.y <= region.maxY
        }
    }

    public static func isPointerInChangingRegion(_ pointer: CGPoint, strips: [CGRect], iconFrame: CGRect?) -> Bool {
        isPointerInChangingRegion(pointer, strips: strips, iconFrames: iconFrame.map { [$0] } ?? [])
    }
}
