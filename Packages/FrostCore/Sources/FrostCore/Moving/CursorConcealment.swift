import CoreGraphics
import Synchronization

@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(_ connection: Int32, _ target: Int32, _ key: CFString,
                                      _ value: CFTypeRef) -> Int32

/// Hides the pointer while a synthesized event sequence moves it (a ⌘-drag's mouse-down on the Frost icon and mouse-up
/// at the drop point, a click away from the pointer), so the user doesn't see it jump there and back.
///
/// Frost is an accessory app that is almost never active, and `CGDisplayHideCursor` from an inactive app is ignored
/// unless its connection sets the (private) `SetsCursorInBackground` property, the same thing Ice does (measured in
/// the VM on macOS 26, see macos-behavior.md, "Hiding the pointer during synthesized events"). If setting it fails,
/// hiding is a harmless no-op and the pointer is still restored as before.
///
/// Every `begin()` is balanced by exactly one `CGDisplayShowCursor`: `end` is idempotent and thread-safe, and `deinit`
/// ends a concealment nobody ended (a thrown error, cancellation). If the process dies while hidden, the window server
/// shows the pointer again with the connection gone.
public final class CursorConcealment: Sendable {
    private let ended = Mutex(false)

    private static let allowedInBackground: Bool = {
        let connection = CGSMainConnectionID()
        let status = CGSSetConnectionProperty(connection, connection, "SetsCursorInBackground" as CFString,
                                              kCFBooleanTrue)
        if status != 0 {
            FrostLog.mover.error("SetsCursorInBackground failed (\(status, privacy: .public)); the pointer stays visible")
        }
        return status == 0
    }()

    private init() {}

    /// Hides the pointer until `end`. Any thread.
    public static func begin() -> CursorConcealment {
        _ = allowedInBackground
        CGDisplayHideCursor(CGMainDisplayID())
        return CursorConcealment()
    }

    /// Moves the pointer to `point` (if any) while still hidden, then shows it. Only the first call does anything.
    public func end(warpingTo point: CGPoint? = nil) {
        let first = ended.withLock { done in
            defer { done = true }
            return !done
        }
        guard first else { return }
        if let point { CGWarpMouseCursorPosition(point) }
        CGDisplayShowCursor(CGMainDisplayID())
    }

    deinit { end() }
}
