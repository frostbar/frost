// Run inside the guest: every ~10 ms logs (epoch seconds), whenever it changes, the number of Frost freeze-frame windows
// (layer 26, or 501 for the background capture's; "W" when one reaches the right edge of the main display, i.e. a
// whole-bar freeze frame) and of drag-image windows (layer 500), the pointer location, and the status item order (window
// IDs left to right; on-screen ones with their x). Pair it with `screencapture -v -C` (see docs/testing-vm.md,
// "Verification techniques").
//   /tmp/guest-menubar-probe <seconds> <out>
import CoreGraphics
import Foundation

let args = CommandLine.arguments
let seconds = Double(args[1])!
// Start from an empty file (FileHandle(forWritingAtPath:) doesn't truncate).
FileManager.default.createFile(atPath: args[2], contents: nil)
let out = FileHandle(forWritingAtPath: args[2])!
let main = CGDisplayBounds(CGMainDisplayID())
let end = Date().addingTimeInterval(seconds)
var lastOrder = ""
var lastFreeze = ""
var lastCursor = CGPoint(x: -1, y: -1)
while Date() < end {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    var freeze = 0
    var whole = false
    for w in list where [26, 501].contains(w[kCGWindowLayer as String] as? Int ?? 0) && (w[kCGWindowOwnerName as String] as? String) == "Frost" {
        freeze += 1
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        if (b["X"] ?? 0) + (b["Width"] ?? 0) >= main.maxX - 1 { whole = true }
    }
    let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    var rows: [(Double, Int, Bool)] = []
    for w in all where (w[kCGWindowLayer as String] as? Int) == 25 {
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        guard abs((b["Y"] ?? -1) - main.minY) < 1, (b["Height"] ?? 99) < 60 else { continue }
        rows.append((b["X"] ?? 0, w[kCGWindowNumber as String] as? Int ?? 0, (w[kCGWindowIsOnscreen as String] as? Bool) == true))
    }
    rows.sort { ($0.0, $0.1) < ($1.0, $1.1) }
    let order = rows.map { "\($0.1)" }.joined(separator: ",")
    let onScreen = rows.filter { $0.2 }.map { "\($0.1)@\(Int($0.0))" }.joined(separator: ",")
    let cursor = CGEvent(source: nil)?.location ?? .zero
    let t = String(format: "%.3f", Date().timeIntervalSince1970)
    let drags = list.filter { ($0[kCGWindowLayer as String] as? Int) == 500 }.count
    let f = "\(freeze)\(whole ? "W" : "") drag \(drags)"
    var line = ""
    if f != lastFreeze { line += "\(t) freeze \(f)\n"; lastFreeze = f }
    if cursor != lastCursor { line += "\(t) cursor \(Int(cursor.x)),\(Int(cursor.y))\n"; lastCursor = cursor }
    if order + onScreen != lastOrder { line += "\(t) order \(order)\n\(t) onscreen \(onScreen)\n"; lastOrder = order + onScreen }
    if !line.isEmpty { out.write(line.data(using: .utf8)!) }
    usleep(10_000)
}
