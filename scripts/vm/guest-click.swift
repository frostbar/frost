// Run inside the guest: a synthetic left click like Frost's ItemClicker.postClick (down/up, clickState 1,
// field 0x33 = windowID; 30 ms apart). Posted to the session tap; HIDTAP=1 posts to the HID tap, as Frost does.
// (Frost also sends a lone mouse-up first and supports right / Option clicks.)
//   /tmp/guest-click <x> <y> <windowID> [downUpDelayMs]     (points)
import CoreGraphics
import Foundation
let a = CommandLine.arguments
guard a.count >= 4, let x = Double(a[1]), let y = Double(a[2]), let wid = Int64(a[3]) else {
    print("usage: x y windowID [delayMs]"); exit(2)
}
let delay = a.count > 4 ? UInt32(a[4])! * 1000 : 30_000
let src = CGEventSource(stateID: .hidSystemState)
let saved = CGEvent(source: nil)?.location
for type in [CGEventType.leftMouseDown, .leftMouseUp] {
    let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)!
    e.flags = []
    e.setIntegerValueField(.mouseEventClickState, value: 1)
    if wid != 0 { e.setIntegerValueField(CGEventField(rawValue: 0x33)!, value: wid) }
    e.post(tap: ProcessInfo.processInfo.environment["HIDTAP"] != nil ? .cghidEventTap : .cgSessionEventTap)
    usleep(delay)
}
if let saved { CGWarpMouseCursorPosition(saved) }
