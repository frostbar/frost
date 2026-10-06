// Run inside the guest over SSH (window titles need Screen Recording, which the image pre-grants to
// sshd-keygen-wrapper): print each status item's Frost section, judged only from the menu bar's geometry, so the
// answer doesn't depend on any Frost version's stored state.
//
//   swiftc -O -o /tmp/guest-sections guest-sections.swift && /tmp/guest-sections [--json]
//
// The status item windows (layer 25) on the main display's menu bar row are sorted left to right; Frost's own three
// windows are found by their titles (the autosave names FrostIcon, FrostHiddenSeparator,
// FrostAlwaysHiddenSeparator). Left of the Always Hidden separator: always-hidden; from there up to the icon:
// hidden; right of the icon: visible. Works collapsed and expanded: a collapsed separator is 5016 pt wide and pushes
// the items on its left off screen, but their order is kept.
//
// Items are named by their window titles, i.e. their apps' autosave names (FakeItems: the spec names, e.g. FIMenuA;
// other apps: e.g. Item-0, Clock). Windows without a title or width are skipped. When a title appears more than once
// (a window left behind by an app that quit, or by an item its app re-created), the newest window (highest ID) counts.
// Exits with 2 when Frost's windows are not in the menu bar.
//
// Output: "<section> <title> x=<x> w=<width> id=<window id>" per item, left to right. --json: one object
// {"sections": {title: section}, "frost": {icon / hidden / alwaysHidden: {x, width}}, "windows": [titles of Frost's
// normal (layer 0) windows on screen, e.g. onboarding or Settings]}.
import CoreGraphics
import Foundation

let json = CommandLine.arguments.contains("--json")
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
let main = CGDisplayBounds(CGMainDisplayID())

struct Window {
    let id: Int
    let title: String
    let x: Double
    let width: Double
}

var byTitle: [String: Window] = [:]
var frostWindows: [String] = []
for info in list {
    let layer = info[kCGWindowLayer as String] as? Int ?? -1
    let title = info[kCGWindowName as String] as? String ?? ""
    let onScreen = (info[kCGWindowIsOnscreen as String] as? Bool) == true
    if layer == 0, onScreen, (info[kCGWindowOwnerName as String] as? String) == "Frost" {
        frostWindows.append(title.isEmpty ? "(untitled)" : title)
    }
    guard layer == 25, !title.isEmpty else { continue }
    let bounds = info[kCGWindowBounds as String] as? [String: Double] ?? [:]
    let y = bounds["Y"] ?? 0, height = bounds["Height"] ?? 0, width = bounds["Width"] ?? 0
    guard height < 60, abs(y - main.minY) < 1, width > 0 else { continue }
    let window = Window(id: info[kCGWindowNumber as String] as? Int ?? 0, title: title, x: bounds["X"] ?? 0,
                        width: width)
    if let existing = byTitle[title], existing.id > window.id { continue }
    byTitle[title] = window
}

guard let icon = byTitle["FrostIcon"], let hidden = byTitle["FrostHiddenSeparator"],
      let alwaysHidden = byTitle["FrostAlwaysHiddenSeparator"] else {
    FileHandle.standardError.write(Data("Frost's status items are not in the menu bar (is Frost running?)\n".utf8))
    exit(2)
}
let frostTitles: Set<String> = [icon.title, hidden.title, alwaysHidden.title]

func section(of window: Window) -> String {
    if window.x < alwaysHidden.x { return "always-hidden" }
    if window.x < icon.x { return "hidden" }
    return "visible"
}

let items = byTitle.values.filter { !frostTitles.contains($0.title) }.sorted { $0.x < $1.x }
if json {
    func frame(_ window: Window) -> [String: Double] { ["x": window.x, "width": window.width] }
    let object: [String: Any] = [
        "sections": Dictionary(uniqueKeysWithValues: items.map { ($0.title, section(of: $0)) }),
        "frost": ["icon": frame(icon), "hidden": frame(hidden), "alwaysHidden": frame(alwaysHidden)],
        "windows": frostWindows,
    ]
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} else {
    for window in items {
        let name = section(of: window).padding(toLength: 13, withPad: " ", startingAt: 0)
        print("\(name) \(window.title) x=\(Int(window.x)) w=\(Int(window.width)) id=\(window.id)")
    }
}
