// Run inside the guest's GUI session: measures the Frost Bar's click-to-menu latency (docs/testing-vm.md,
// "Verification techniques"). For each run it opens the Frost Bar with a HID click on the snowflake (⌥ with --ah),
// waits, clicks the item's tile (found through Frost's accessibility tree) with a HID click, then samples the window
// list every ~4 ms until the item's menu / popover appears, checks where it appeared (menu left-aligned with the item,
// popover centered under it), closes it with a click on the desktop and waits until the item is back in its slot.
//   /tmp/guest-click-latency <statusWindowTitle> <tileLabelSubstring> [--ah] [--dwell s] [--runs n] [--gap s]
// statusWindowTitle is the item's window title (its autosave name, see dump-status-windows.swift). Prints one JSON
// line per run (times in ms since the tile's mouse-up; epoch = wall clock of the mouse-up, to match Frost's log).
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    print("usage: guest-click-latency <windowTitle> <tileLabel> [--ah] [--dwell s] [--runs n] [--gap s]"); exit(2)
}
let title = args[0], tileLabel = args[1]
func option(_ name: String, _ fallback: Double) -> Double {
    guard let i = args.firstIndex(of: name), i + 1 < args.count, let v = Double(args[i + 1]) else { return fallback }
    return v
}
let alwaysHidden = args.contains("--ah")
let listTiles = args.contains("--list")
let dwell = option("--dwell", 4), runs = Int(option("--runs", 10)), gap = option("--gap", 1.5)

struct Win { let id: CGWindowID; let layer: Int; let pid: pid_t; let frame: CGRect; let name: String; let onScreen: Bool }
func windows(_ options: CGWindowListOption) -> [Win] {
    (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { w in
        guard let n = w[kCGWindowNumber as String] as? Int else { return nil }
        let b = (w[kCGWindowBounds as String] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
        return Win(id: CGWindowID(n), layer: w[kCGWindowLayer as String] as? Int ?? 0,
                   pid: pid_t(w[kCGWindowOwnerPID as String] as? Int ?? 0), frame: b,
                   name: w[kCGWindowName as String] as? String ?? "",
                   onScreen: (w[kCGWindowIsOnscreen as String] as? Bool) == true)
    }
}
func statusWindows() -> [Win] {
    windows([.optionAll]).filter { $0.layer == 25 && $0.frame.minY == 0 && $0.frame.height < 60 }
}
func frame(of id: CGWindowID) -> CGRect? {
    var ids = [UnsafeRawPointer(bitPattern: UInt(id))]
    let arr = CFArrayCreate(nil, &ids, 1, nil)!
    guard let d = (CGWindowListCreateDescriptionFromArray(arr) as? [[String: Any]])?.first,
          let b = d[kCGWindowBounds as String] as? [String: Any] else { return nil }
    return CGRect(dictionaryRepresentation: b as CFDictionary)
}
let clock = ContinuousClock()
func ms(_ d: Duration) -> Double { (d / .microseconds(1)) / 1000 }

let src = CGEventSource(stateID: .hidSystemState)
func hidClick(_ p: CGPoint, flags: CGEventFlags = []) {
    for t in [CGEventType.leftMouseDown, .leftMouseUp] {
        let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)!
        e.flags = flags
        e.setIntegerValueField(.mouseEventClickState, value: 1)
        e.post(tap: .cghidEventTap)
        if t == .leftMouseDown { usleep(40_000) }
    }
}

guard let frost = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.frost.Frost").first else {
    print("Frost is not running"); exit(1)
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
/// The tile whose accessibility label contains `tileLabel`, in Frost's windows.
func findTile() -> CGRect? {
    let app = AXUIElementCreateApplication(frost.processIdentifier)
    var queue = (axCopy(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    while !queue.isEmpty {
        let e = queue.removeFirst()
        let label = (axCopy(e, kAXDescriptionAttribute) as? String) ?? ""
        if listTiles, (axCopy(e, kAXRoleAttribute) as? String) == kAXButtonRole { print("tile: \(label) \(axFrame(e) ?? .zero)") }
        if !listTiles, label.contains(tileLabel), (axCopy(e, kAXRoleAttribute) as? String) == kAXButtonRole, let f = axFrame(e) {
            return f
        }
        queue += (axCopy(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
    return nil
}
/// Frost's panel: an on-screen Frost window below the menu bar (not the freeze frame, layer 26).
func panelOnScreen() -> Bool {
    windows([.optionOnScreenOnly]).contains { $0.pid == frost.processIdentifier && $0.layer != 26 && $0.layer != 25
        && $0.frame.minY > 0 && $0.frame.height > 20 }
}

func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? .nan : s[s.count / 2] }
func p90(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? .nan : s[min(s.count - 1, Int((Double(s.count) * 0.9).rounded(.up)) - 1)] }
var latencies: [Double] = [], failures = 0

for run in 1...runs {
    guard let item = statusWindows().first(where: { $0.name == title }),
          let icon = statusWindows().first(where: { $0.name == "FrostIcon" }) else { print("item/icon missing"); exit(1) }
    let originalOrder = statusWindows().sorted { $0.frame.minX < $1.frame.minX }.map(\.id)
    let original = item.frame
    // Open the Frost Bar.
    hidClick(CGPoint(x: icon.frame.midX, y: icon.frame.midY), flags: alwaysHidden ? .maskAlternate : [])
    let openStart = clock.now
    while !panelOnScreen(), clock.now - openStart < .seconds(2) { usleep(5_000) }
    try? await Task.sleep(for: .seconds(dwell))
    if listTiles { _ = findTile(); hidClick(CGPoint(x: icon.frame.midX, y: icon.frame.midY)); exit(0) }
    guard let tile = findTile() else {
        print("{\"run\":\(run),\"error\":\"tile not found\"}"); failures += 1
        hidClick(CGPoint(x: icon.frame.midX, y: icon.frame.midY)); sleep(2); continue
    }
    let baseline = Set(windows([.optionOnScreenOnly]).map(\.id))
    let fakePID = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.frost.FakeItems").first?.processIdentifier ?? -1
    // Click the tile (the SwiftUI button acts on mouse-up; t = 0 is the mouse-up).
    let p = CGPoint(x: tile.midX, y: tile.midY)
    let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)!
    let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)!
    for e in [down, up] { e.setIntegerValueField(.mouseEventClickState, value: 1) }
    down.post(tap: .cghidEventTap); usleep(40_000)
    up.post(tap: .cghidEventTap)
    let t0 = clock.now, epoch = Date().timeIntervalSince1970
    var panelGone: Double?, lifted: Double?, lastMove: Double?, presented: Double?, presentation: Win?
    var frames: [(Double, CGRect)] = [(0, original)]
    var movedAfterPresent = false
    var atPresent: CGRect?
    while clock.now - t0 < .seconds(6) {
        let t = ms(clock.now - t0)
        let on = windows([.optionOnScreenOnly])
        if panelGone == nil, !on.contains(where: { $0.pid == frost.processIdentifier && $0.layer != 26 && $0.layer != 25 && $0.frame.minY > 0 && $0.frame.height > 20 }) { panelGone = t }
        if let f = frame(of: item.id), f != frames.last!.1 {
            frames.append((t, f))
            if lifted == nil { lifted = t }
            // Ignore shifts of a few points: a neighbour whose width changes (a ticking clock) shifts the item with it.
            if let atPresent { if abs(f.minX - atPresent.minX) > 4 { movedAfterPresent = true } } else { lastMove = t }
        }
        if presented == nil, let w = on.first(where: { !baseline.contains($0.id) && !($0.frame.minY == 0 && $0.frame.height < 60)
            && ($0.layer == 101 || ($0.pid == fakePID && $0.layer < 500)) }) {
            presented = t; presentation = w; atPresent = frames.last!.1
        }
        if let presented, t - presented > 400 { break }
        usleep(4_000)
    }
    let final = atPresent ?? frames.last!.1
    var positionOK = false
    var placement = "none"
    if let w = presentation {
        if w.layer == 101 {
            positionOK = abs(w.frame.minX - (final.minX - 4)) <= 6
            placement = "menu dx=\(Int(w.frame.minX - final.minX))"
        } else {
            positionOK = abs(w.frame.midX - final.midX) <= 4
            placement = "popover dmid=\(Int(w.frame.midX - final.midX))"
        }
    }
    // The item sits immediately right of the snowflake (by order: a ticking neighbour may shift frames by a point or two).
    let orderNow = statusWindows().sorted { $0.frame.minX < $1.frame.minX }.map(\.id)
    let rightOfIcon = orderNow.firstIndex(of: item.id).map { $0 > 0 && orderNow[$0 - 1] == icon.id } ?? false
    // Close the presentation with a click on the desktop, then wait for the item to return to its slot.
    hidClick(CGPoint(x: 860, y: 700))
    let closeStart = clock.now
    var restored: Double?
    while clock.now - closeStart < .seconds(8) {
        let order = statusWindows().sorted { $0.frame.minX < $1.frame.minX }.map(\.id)
        if order == originalOrder { restored = ms(clock.now - closeStart); break }
        usleep(20_000)
    }
    if let presented { latencies.append(presented) }
    let ok = presented != nil && positionOK && rightOfIcon && !movedAfterPresent && restored != nil
    if !ok { failures += 1 }
    func f(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "null" }
    let moves = frames.dropFirst().map { "\(Int($0.0)):\(Int($0.1.minX))" }.joined(separator: " ")
    print("""
        {"run":\(run),"epoch":\(String(format: "%.3f", epoch)),"panelGone":\(f(panelGone)),"lifted":\(f(lifted)),\
        "lastMove":\(f(lastMove)),"presented":\(f(presented)),"placement":"\(placement)","positionOK":\(positionOK),\
        "rightOfIcon":\(rightOfIcon),"movedAfterPresent":\(movedAfterPresent),"restoredAfterClose":\(f(restored)),\
        "ok":\(ok),"moves":"\(moves)"}
        """)
    fflush(stdout)
    try? await Task.sleep(for: .seconds(gap))
}
print(String(format: "SUMMARY %@ dwell=%.2f runs=%d failures=%d median=%.0f p90=%.0f min=%.0f max=%.0f", title, dwell, runs,
             failures, median(latencies), p90(latencies), latencies.min() ?? .nan, latencies.max() ?? .nan))
