import CoreGraphics

/// Whether the user is holding a mouse button, for work that must never start a synthetic ⌘-drag meanwhile.
///
/// Read from the HID system state, not `NSEvent.pressedMouseButtons` (the combined session state): `ItemMover` posts
/// its ⌘-drags at the session event tap, and their mouse-up clears the session state while the user still holds the
/// button (measured in the VM: a new-item batch went on moving items during the user's drag-select). Events posted at
/// the session tap leave the HID state alone.
public enum UserMouseButtons {
    public static var isAnyHeld: Bool {
        [CGMouseButton.left, .right, .center].contains { CGEventSource.buttonState(.hidSystemState, button: $0) }
    }
}
