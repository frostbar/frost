// Run inside the guest's GUI session: cursor facts for synthesized ⌘-drags (docs/testing-vm.md, "Verification
// techniques").
//   /tmp/guest-cursor-probe hide [--background]   an accessory (never active) process hides the cursor with
//       CGDisplayHideCursor and captures the area around it (screencapture -C) visible / hidden / shown again;
//       --background first sets the "SetsCursorInBackground" connection property. Prints whether the hidden capture
//       differs from the visible one, and writes the PNGs to /tmp/cursor-hide-*.png.
//   /tmp/guest-cursor-probe trace <seconds> [<file>]   samples the cursor position every 10 ms and prints the
//       jumps (one JSON line per sample whose position changed: t = ms since the start, epoch, x, y).
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSSetConnectionProperty")
func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

let args = Array(CommandLine.arguments.dropFirst())
func cursor() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

func capture(_ name: String, around p: CGPoint) -> Data {
    let path = "/tmp/cursor-hide-\(name).png"
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-C", "-R", "\(Int(p.x) - 30),\(Int(p.y) - 30),60,60", path]
    try? task.run()
    task.waitUntilExit()
    return (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
}

switch args.first {
case "hide":
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    if args.contains("--background") {
        let cid = CGSMainConnectionID()
        let r = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        print("SetsCursorInBackground -> \(r)")
    }
    let p = CGPoint(x: 400, y: 400)
    CGWarpMouseCursorPosition(p)
    usleep(300_000)
    print("frontmost: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"), self active: \(app.isActive)")
    let visible = capture("visible", around: p)
    let hideErr = CGDisplayHideCursor(CGMainDisplayID())
    usleep(300_000)
    let hidden = capture("hidden", around: p)
    // While hidden, warp elsewhere and back: a visible cursor would show up in the capture at the new spot.
    CGWarpMouseCursorPosition(CGPoint(x: 500, y: 400))
    usleep(200_000)
    let hiddenMoved = capture("hidden-moved", around: CGPoint(x: 500, y: 400))
    CGWarpMouseCursorPosition(p)
    let showErr = CGDisplayShowCursor(CGMainDisplayID())
    usleep(300_000)
    let shown = capture("shown", around: p)
    print("""
        {"hideErr":\(hideErr.rawValue),"showErr":\(showErr.rawValue),"hiddenDiffers":\(hidden != visible),\
        "shownMatchesVisible":\(shown == visible),"bytes":[\(visible.count),\(hidden.count),\(hiddenMoved.count),\(shown.count)]}
        """)
case "trace":
    let seconds = Double(args.count > 1 ? args[1] : "10") ?? 10
    let clock = ContinuousClock()
    let start = clock.now
    var last = CGPoint(x: -1, y: -1)
    var lines: [String] = []
    while clock.now - start < .seconds(seconds) {
        let p = cursor()
        if p != last {
            let t = (clock.now - start) / .milliseconds(1)
            let line = String(format: "{\"t\":%.0f,\"epoch\":%.3f,\"x\":%.0f,\"y\":%.0f}", t,
                              Date().timeIntervalSince1970, p.x, p.y)
            lines.append(line)
            last = p
        }
        usleep(10_000)
    }
    let out = lines.joined(separator: "\n") + "\n"
    if args.count > 2 { try? out.write(toFile: args[2], atomically: true, encoding: .utf8) } else { print(out) }
case "forward":
    // forward <tileLabel> <left|right> <outfile>: like a user, opens the Frost Bar with a click on the snowflake,
    // rests the pointer on the tile and clicks it, presses Esc after 1.5 s to close the menu, moves the pointer away
    // to the desktop after 1 s more, and samples the pointer every 5 ms throughout (until the item has moved back).
    // Writes the changes of position with event markers to <outfile>.
    guard args.count >= 4 else { print("usage: forward <tileLabel> <left|right> <outfile>"); exit(2) }
    let tileLabel = args[1], right = args[2] == "right", outfile = args[3]
    guard let frost = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.frost.Frost").first else {
        print("Frost is not running"); exit(1)
    }
    func axCopy(_ e: AXUIElement, _ a: String) -> AnyObject? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }
    func findTile() -> CGRect? {
        var queue = (axCopy(AXUIElementCreateApplication(frost.processIdentifier), kAXWindowsAttribute) as? [AXUIElement]) ?? []
        while !queue.isEmpty {
            let e = queue.removeFirst()
            if ((axCopy(e, kAXDescriptionAttribute) as? String) ?? "").contains(tileLabel),
               (axCopy(e, kAXRoleAttribute) as? String) == kAXButtonRole,
               let p = axCopy(e, kAXPositionAttribute), let s = axCopy(e, kAXSizeAttribute) {
                var pt = CGPoint.zero, sz = CGSize.zero
                AXValueGetValue(p as! AXValue, .cgPoint, &pt); AXValueGetValue(s as! AXValue, .cgSize, &sz)
                return CGRect(origin: pt, size: sz)
            }
            queue += (axCopy(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        return nil
    }
    func statusFrame(_ title: String) -> CGRect? {
        for w in (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []) {
            guard (w[kCGWindowLayer as String] as? Int) == 25, (w[kCGWindowName as String] as? String) == title,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let f = CGRect(dictionaryRepresentation: b as CFDictionary), f.minY == 0 else { continue }
            return f
        }
        return nil
    }
    let src = CGEventSource(stateID: .hidSystemState)
    func click(_ p: CGPoint, right: Bool = false) {
        let (d, u): (CGEventType, CGEventType) = right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        for t in [d, u] {
            let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: right ? .right : .left)!
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            e.post(tap: .cghidEventTap)
            if t == d { usleep(40_000) }
        }
    }
    func move(_ p: CGPoint) {
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
    let clock = ContinuousClock()
    let start = clock.now
    let lock = NSLock()
    var lines: [String] = []
    func note(_ s: String) {
        let t = (clock.now - start) / .milliseconds(1)
        lock.lock(); lines.append(String(format: "{\"t\":%.0f,\"event\":\"%@\"}", t, s)); lock.unlock()
    }
    var sampling = true
    let sampler = Thread {
        var last = CGPoint(x: -1, y: -1)
        while true {
            lock.lock(); let go = sampling; lock.unlock()
            if !go { break }
            let p = cursor()
            if p != last {
                let t = (clock.now - start) / .milliseconds(1)
                lock.lock(); lines.append(String(format: "{\"t\":%.0f,\"x\":%.0f,\"y\":%.0f}", t, p.x, p.y)); lock.unlock()
                last = p
            }
            usleep(5_000)
        }
    }
    sampler.start()
    guard let icon = statusFrame("FrostIcon") else { print("no Frost icon"); exit(1) }
    move(CGPoint(x: 400, y: 400)); usleep(300_000)
    note("open panel"); click(CGPoint(x: icon.midX, y: icon.midY)); usleep(1_200_000)
    guard let tile = findTile() else { print("tile not found"); exit(1) }
    move(CGPoint(x: tile.midX, y: tile.midY)); usleep(300_000)
    note("click tile"); click(CGPoint(x: tile.midX, y: tile.midY), right: right)
    usleep(1_500_000)
    note("esc")
    for down in [true, false] {
        CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap)
    }
    usleep(1_000_000)
    note("user moves away"); move(CGPoint(x: 400, y: 500))
    usleep(5_000_000)
    note("end")
    lock.lock(); sampling = false; lock.unlock()
    usleep(50_000)
    try? (lines.joined(separator: "\n") + "\n").write(toFile: outfile, atomically: true, encoding: .utf8)
    print("wrote \(lines.count) lines to \(outfile)")
default:
    print("usage: guest-cursor-probe hide [--background] | trace <seconds> [<file>] | forward <tile> <left|right> <file>")
    exit(2)
}
