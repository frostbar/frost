// Run inside the guest: a user's click on the menu bar timed against Frost's move back of an item it moved out (a click
// forward's move back after the linger, or a background capture's), with real HID events (`.cghidEventTap`, no 0x33
// field), like the user's own mouse.
//
//   /tmp/guest-moveback-click lift <windowID> <x> <y> [delayMs] [holdMs] [timeout] [right]
//     Waits (up to `timeout` s, default 60) until the item's window is on screen, then until its frame changes (the
//     move back's mouse-down lifts it ~15-100 ms after the event), waits `delayMs` (default 0), then clicks at (x, y)
//     (points), holding the button `holdMs` (default 80).
//   /tmp/guest-moveback-click away <awayX> <awayY> <x> <y> <delayMs> [holdMs] [right]
//     Moves the pointer to (awayX, awayY) right away (the linger moves the item back 0.75 s after the pointer left it,
//     checked every 0.1 s), waits `delayMs`, then clicks at (x, y). Sweep `delayMs` around 750-900 to press just before
//     or during the move back's ⌘-drag.
// Prints when it saw the lift (lift mode) and posted the down / up (epoch seconds, as in Frost's log).
import CoreGraphics
import Foundation

let a = CommandLine.arguments
guard a.count >= 2 else { print("usage: lift|away ..."); exit(2) }
let source = CGEventSource(stateID: .hidSystemState)
func now() -> Double { Date().timeIntervalSince1970 }

func post(_ type: CGEventType, _ point: CGPoint, _ button: CGMouseButton) {
    let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)!
    if type != .mouseMoved { e.setIntegerValueField(.mouseEventClickState, value: 1) }
    e.post(tap: .cghidEventTap)
}

func click(_ point: CGPoint, hold: UInt32, right: Bool) -> (down: Double, up: Double) {
    let (down, up, button): (CGEventType, CGEventType, CGMouseButton) = right
        ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
    post(down, point, button)
    let downAt = now()
    usleep(hold * 1000)
    post(up, point, button)
    return (downAt, now())
}

func frame(of windowID: CGWindowID) -> (CGRect, Bool)? {
    guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
          let info = list.first, let bounds = info[kCGWindowBounds as String] as? NSDictionary,
          let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
    return (rect, (info[kCGWindowIsOnscreen as String] as? Bool) ?? false)
}

switch a[1] {
case "lift":
    guard a.count >= 5, let wid = UInt32(a[2]), let x = Double(a[3]), let y = Double(a[4]) else { exit(2) }
    let delay = a.count > 5 ? UInt32(a[5])! : 0
    let hold = a.count > 6 ? UInt32(a[6])! : 80
    let timeout = a.count > 7 ? Double(a[7])! : 60
    let right = a.count > 8 && a[8] == "right"
    let end = Date().addingTimeInterval(timeout)
    var parked: CGRect?
    while parked == nil {
        if let (rect, onScreen) = frame(of: wid), onScreen, rect.minX >= 0 { parked = rect }
        guard Date() < end else { print("item never on screen"); exit(1) }
        usleep(2_000)
    }
    // Stable on screen for a moment (the move out itself has landed), then wait for the next change.
    usleep(300_000)
    parked = frame(of: wid)?.0
    while let (rect, _) = frame(of: wid), rect == parked {
        guard Date() < end else { print("item never lifted"); exit(1) }
        usleep(1_000)
    }
    let liftAt = now()
    usleep(delay * 1000)
    let (downAt, upAt) = click(CGPoint(x: x, y: y), hold: hold, right: right)
    print(String(format: "lift seen %.3f, down %.3f (+%.0f ms), up %.3f", liftAt, downAt, (downAt - liftAt) * 1000,
                 upAt))
case "away":
    guard a.count >= 7, let ax = Double(a[2]), let ay = Double(a[3]), let x = Double(a[4]), let y = Double(a[5]),
          let delay = UInt32(a[6]) else { exit(2) }
    let hold = a.count > 7 ? UInt32(a[7])! : 80
    let right = a.count > 8 && a[8] == "right"
    post(.mouseMoved, CGPoint(x: ax, y: ay), .left)
    let awayAt = now()
    usleep(delay * 1000)
    let (downAt, upAt) = click(CGPoint(x: x, y: y), hold: hold, right: right)
    print(String(format: "away %.3f, down %.3f (+%.0f ms), up %.3f", awayAt, downAt, (downAt - awayAt) * 1000, upAt))
default:
    print("usage: lift|away ...")
    exit(2)
}
