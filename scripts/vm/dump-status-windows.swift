// Run inside the guest (scripts/vm/vm-exec.sh 'swift /tmp/dump-status-windows.swift [--all]'):
// print the menu bar's status item windows (layer 25, top row of the main display)
// left to right: x, width, onscreen flag, owner and title. Titles need Screen
// Recording, which the image pre-grants to sshd-keygen-wrapper.
// `--all`: every display's menu bar row (replicas on other displays too) with y, height and the display
// list first — for multi-display tests (scripts/vm/guest-virtual-display.m).
import CoreGraphics
import Foundation
let all = CommandLine.arguments.contains("--all")
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
let main = CGDisplayBounds(CGMainDisplayID())
var count: UInt32 = 0
CGGetActiveDisplayList(0, nil, &count)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
CGGetActiveDisplayList(count, &ids, &count)
let displays = ids.map { ($0, CGDisplayBounds($0)) }
if all {
    for (id, b) in displays {
        print(String(format: "display %u%@ (%.0f, %.0f, %.0f, %.0f)", id, id == CGMainDisplayID() ? " main" : "",
                     b.minX, b.minY, b.width, b.height))
    }
}
var rows: [(Double, Double, String)] = []
for w in list where (w[kCGWindowLayer as String] as? Int) == 25 {
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    let x = b["X"] ?? 0, y = b["Y"] ?? 0, width = b["Width"] ?? 0, h = b["Height"] ?? 0
    guard h < 60, all ? displays.contains(where: { abs(y - $0.1.minY) < 1 }) : abs(y - main.minY) < 1 else { continue }
    let on = (w[kCGWindowIsOnscreen as String] as? Bool) == true ? "on " : "off"
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let name = w[kCGWindowName as String] as? String ?? ""
    let id = w[kCGWindowNumber as String] as? Int ?? 0
    let text = all
        ? String(format: "%6.0f %8.0f %6.0f %3.0f %@ %6d %@ | %@", y, x, width, h, on, id, owner, name)
        : String(format: "%8.0f %6.0f %@ %6d %@ | %@", x, width, on, id, owner, name)
    rows.append((y, x, text))
}
for r in rows.sorted(by: { ($0.0, $0.1) < ($1.0, $1.1) }) { print(r.2) }
