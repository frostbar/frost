// Run inside the guest: interrupts Frost's background capture of items behind the notch like a user would. Waits (up
// to `timeout` s, default 120) for its whole-bar freeze frame (a Frost window at layer 26 / 501 reaching the right edge
// of the main display), waits `delayMs`, then posts a real HID mouse-down at (x, y) (points; `right` = right button),
// holds it `holdMs`, and releases. Prints when it saw the freeze frame and posted the events (epoch seconds).
//   [RETURN_AFTER_MS=ms] /tmp/guest-interrupt <x> <y> <delayMs> <holdMs> [timeout] [right]
import CoreGraphics
import Foundation

let a = CommandLine.arguments
let x = Double(a[1])!, y = Double(a[2])!
let delay = UInt32(a[3])!, hold = UInt32(a[4])!
let timeout = a.count > 5 ? Double(a[5])! : 120
let right = a.count > 6 && a[6] == "right"
let main = CGDisplayBounds(CGMainDisplayID())
let end = Date().addingTimeInterval(timeout)
func wholeBarFreeze() -> Bool {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.contains { w in
        guard [26, 501].contains(w[kCGWindowLayer as String] as? Int ?? 0), (w[kCGWindowOwnerName as String] as? String) == "Frost"
        else { return false }
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        return (b["X"] ?? 0) + (b["Width"] ?? 0) >= main.maxX - 1
    }
}
while !wholeBarFreeze() {
    guard Date() < end else { print("no freeze frame seen"); exit(1) }
    usleep(5_000)
}
let seenAt = Date().timeIntervalSince1970
usleep(delay * 1000)
let src = CGEventSource(stateID: .hidSystemState)
let original = CGEvent(source: nil)?.location
let point = CGPoint(x: x, y: y)
let (down, up, button): (CGEventType, CGEventType, CGMouseButton) = right
    ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
let d = CGEvent(mouseEventSource: src, mouseType: down, mouseCursorPosition: point, mouseButton: button)!
d.setIntegerValueField(.mouseEventClickState, value: 1)
d.post(tap: .cghidEventTap)
let downAt = Date().timeIntervalSince1970
usleep(hold * 1000)
let u = CGEvent(mouseEventSource: src, mouseType: up, mouseCursorPosition: point, mouseButton: button)!
u.setIntegerValueField(.mouseEventClickState, value: 1)
u.post(tap: .cghidEventTap)
print(String(format: "freeze seen %.3f, down %.3f, up %.3f", seenAt, downAt, Date().timeIntervalSince1970))
// RETURN_AFTER_MS=<ms>: then move the pointer back where it was before the click (a HID mouse-moved event, as a user
// moving away), so the next background capture isn't held up by a pointer left on the menu bar.
if let ms = ProcessInfo.processInfo.environment["RETURN_AFTER_MS"].flatMap(UInt32.init), let original {
    usleep(ms * 1000)
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: original, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}
