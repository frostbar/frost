import AppKit
import SwiftUI

/// The Frost Bar window: a borderless, non-activating, transparent panel floating below the menu bar.
///
/// A non-activating panel can become key without activating Frost (so it doesn't take the menu bar from the frontmost
/// app), which lets Esc reach the panel. All visuals (rounded glass panel, shadow, name bar) are drawn by the SwiftUI
/// content; the window itself is transparent.
final class FrostBarPanel: NSPanel {
    /// Called on Esc (`cancelOperation`).
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        // SwiftUI draws the panel's shadow: a window shadow follows the whole window shape (transparent margins
        // included) and doesn't track the scale-in animation.
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        setAccessibilityLabel(String(localized: "Frost Bar", comment: "Accessibility label of the Frost Bar panel"))
    }

    /// Keep AppKit from pushing the window below the menu bar: the transparent top margin (needed for the shadow) is
    /// meant to overlap the menu bar; otherwise the visible panel would sit one margin too low. The controller computes
    /// the position via `PanelPlacement`.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Main menu "Close Window" (⌘W): borderless windows ignore it by default (no close button); treat it like Esc.
    override func performClose(_ sender: Any?) {
        onCancel?()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performClose(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }

    /// SwiftUI's hosting view may consume Esc before it travels up the responder chain to `cancelOperation`, so
    /// intercept it before dispatch.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 {
            onCancel?()
            return
        }
        super.sendEvent(event)
    }
}

/// The panel's hosting view: when the SwiftUI content's ideal size changes (AppKit learns of it through
/// `invalidateIntrinsicContentSize`), it tells the controller. Requires `sizingOptions` to include
/// `.intrinsicContentSize` (otherwise there is no intrinsic size and no notification arrives). The window doesn't
/// resize itself; the controller calls `setFrame`. The content stays pinned to the top-trailing corner whatever the
/// window's size (`TopTrailingPin`).
final class FrostBarHostingView: NSHostingView<FrostBarView> {
    var onIntrinsicSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIntrinsicSizeChange?()
    }
}
