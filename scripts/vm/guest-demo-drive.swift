// Run inside the guest's GUI session: drives the README demo (docs/images/demo.gif) with real HID events so the
// pointer moves like a user's, while `screencapture -v -C` records the screen (docs/testing-vm.md, "README demo GIF").
//   /tmp/guest-demo-drive <snowflakeX> <snowflakeY> <tileLabelSubstring> [--list]
// Coordinates are points (global top-left origin). The sequence: the pointer rests mid-screen, glides to the
// snowflake and clicks it, rests on the Frost Bar's tiles, glides to the tile whose accessibility label contains
// the substring and clicks it (its menu opens in the menu bar), reads the menu, presses Esc, and the pointer glides
// back to the middle of the screen. Prints a timestamped line per step.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3, let sx = Double(args[0]), let sy = Double(args[1]) else {
    print("usage: guest-demo-drive <snowflakeX> <snowflakeY> <tileLabel> [--list]"); exit(2)
}
let snowflake = CGPoint(x: sx, y: sy)
let tileLabel = args[2]
let listTiles = args.contains("--list")

guard let frost = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.frost.Frost").first else {
    print("Frost is not running"); exit(1)
}
let src = CGEventSource(stateID: .hidSystemState)
let start = Date()
func note(_ s: String) { print(String(format: "%6.2f  %@", Date().timeIntervalSince(start), s)) }

func post(_ type: CGEventType, _ p: CGPoint) {
    let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)!
    e.setIntegerValueField(.mouseEventClickState, value: 1)
    e.post(tap: .cghidEventTap)
}
var pointer = CGPoint(x: 900, y: 500)
/// Glides the pointer to `target` in `duration` seconds (ease in-out, ~120 Hz events).
func glide(to target: CGPoint, duration: Double) {
    let from = pointer
    let steps = max(2, Int(duration * 120))
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        let k = t * t * (3 - 2 * t)
        let p = CGPoint(x: from.x + (target.x - from.x) * k, y: from.y + (target.y - from.y) * k)
        post(.mouseMoved, p)
        usleep(UInt32(duration / Double(steps) * 1_000_000))
    }
    pointer = target
}
func click(at p: CGPoint) {
    post(.leftMouseDown, p); usleep(70_000); post(.leftMouseUp, p)
}
func pressEsc() {
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: down)!
        e.post(tap: .cghidEventTap)
        usleep(60_000)
    }
}
func axCopy(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
func axFrame(_ e: AXUIElement) -> CGRect? {
    guard let p = axCopy(e, kAXPositionAttribute), let s = axCopy(e, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt); AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}
func findTile() -> CGRect? {
    let app = AXUIElementCreateApplication(frost.processIdentifier)
    var queue = (axCopy(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    while !queue.isEmpty {
        let e = queue.removeFirst()
        let label = (axCopy(e, kAXDescriptionAttribute) as? String) ?? ""
        let isButton = (axCopy(e, kAXRoleAttribute) as? String) == kAXButtonRole
        if listTiles, isButton { print("tile: \(label) \(axFrame(e) ?? .zero)") }
        if !listTiles, isButton, label.contains(tileLabel), let f = axFrame(e) { return f }
        queue += (axCopy(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
    return nil
}

if listTiles {
    glide(to: snowflake, duration: 0.3); click(at: snowflake); sleep(2)
    _ = findTile(); pressEsc(); exit(0)
}

post(.mouseMoved, pointer)
note("rest"); usleep(900_000)
glide(to: snowflake, duration: 0.9)
usleep(250_000)
note("click snowflake"); click(at: snowflake)
usleep(1_000_000)
guard let tile = findTile() else { note("tile not found"); pressEsc(); exit(1) }
let tileCenter = CGPoint(x: tile.midX, y: tile.midY)
note("glide to tile \(tile)")
glide(to: CGPoint(x: tileCenter.x + 30, y: tileCenter.y + 18), duration: 0.5)
glide(to: tileCenter, duration: 0.5)
usleep(300_000)
note("click tile"); click(at: tileCenter)
usleep(1_700_000)
note("esc"); pressEsc()
usleep(600_000)
glide(to: CGPoint(x: 900, y: 500), duration: 0.7)
usleep(1_000_000)
note("done")
