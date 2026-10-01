// Run inside the guest: reproduce Frost's "move out, then click" on one status item.
//   /tmp/guest-moveclick <windowID> <downX> <downY> <dropX> <dropY> [clickX clickY waitMs [clicks]]
// The move is ItemMover.postCommandDrag (Cmd, field 0x33 = windowID, down -> 50 ms -> up);
// the click is ItemClicker.postClick (HID tap, clickState 1, 0x33) after waitMs.
import CoreGraphics
import Foundation
let a = CommandLine.arguments.dropFirst().map { Double($0)! }
guard a.count >= 5 else { print("usage"); exit(2) }
let wid = Int64(a[0])
let src = CGEventSource(stateID: .hidSystemState)
let field = CGEventField(rawValue: 0x33)!
let saved = CGEvent(source: nil)?.location
func ev(_ t: CGEventType, _ x: Double, _ y: Double, _ flags: CGEventFlags) -> CGEvent {
    let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)!
    e.flags = flags
    e.setIntegerValueField(field, value: wid)
    return e
}
ev(.leftMouseDown, a[1], a[2], .maskCommand).post(tap: .cgSessionEventTap)
usleep(50_000)
ev(.leftMouseUp, a[3], a[4], .maskCommand).post(tap: .cgSessionEventTap)
usleep(20_000)
if let saved { CGWarpMouseCursorPosition(saved) }
guard a.count >= 8 else { exit(0) }
usleep(UInt32(a[7] * 1000))
let clicks = a.count > 8 ? Int(a[8]) : 1
// Experiment: PRIME=up|move|up-session posts one event at the click point before the click.
switch ProcessInfo.processInfo.environment["PRIME"] ?? "" {
case "up": ev(.leftMouseUp, a[5], a[6], []).post(tap: .cghidEventTap); usleep(50_000)
case "up-session": ev(.leftMouseUp, a[5], a[6], []).post(tap: .cgSessionEventTap); usleep(50_000)
case "move": ev(.mouseMoved, a[5], a[6], []).post(tap: .cghidEventTap); usleep(50_000)
case "flags":
    let f = CGEvent(source: src)!; f.type = .flagsChanged; f.flags = []; f.post(tap: .cghidEventTap); usleep(50_000)
default: break
}
for n in 0..<clicks {
    for t in [CGEventType.leftMouseDown, .leftMouseUp] {
        let e = ev(t, a[5], a[6], [])
        e.setIntegerValueField(.mouseEventClickState, value: 1)
        e.post(tap: .cghidEventTap)
        usleep(30_000)
    }
    if n + 1 < clicks { usleep(600_000) }
}
if let saved { CGWarpMouseCursorPosition(saved) }
