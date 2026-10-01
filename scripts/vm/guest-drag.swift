// Run inside the guest: a slow left-button drag made of real leftMouseDragged
// events (VNC pointer input does not reliably drive AppKit drag destinations).
//   swift /tmp/guest-drag.swift x0 y0 x1 y1 [steps] [holdSeconds]   (points, top-left origin)
import CoreGraphics
import Foundation
let a = CommandLine.arguments.dropFirst().compactMap(Double.init)
guard a.count >= 4 else { print("usage: x0 y0 x1 y1 [steps] [hold]"); exit(2) }
let (x0, y0, x1, y1) = (a[0], a[1], a[2], a[3])
let steps = a.count > 4 ? Int(a[4]) : 40
let hold = a.count > 5 ? a[5] : 0.4
let src = CGEventSource(stateID: .hidSystemState)
func post(_ type: CGEventType, _ x: Double, _ y: Double) {
    let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)!
    e.post(tap: .cghidEventTap)
}
post(.mouseMoved, x0, y0); usleep(100_000)
post(.leftMouseDown, x0, y0); usleep(150_000)
for i in 1...steps {
    let t = Double(i) / Double(steps)
    post(.leftMouseDragged, x0 + (x1 - x0) * t, y0 + (y1 - y0) * t)
    usleep(20_000)
}
for d in [3.0, 0, -3, 0] { post(.leftMouseDragged, x1 + d, y1); usleep(60_000) }
usleep(UInt32(hold * 1_000_000))
post(.leftMouseUp, x1, y1)
