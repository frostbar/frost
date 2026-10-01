// Run inside the guest: list an app's menu bar extras (AX) and optionally AXPress one.
//   swift /tmp/guest-axpress.swift <pid>            # list
//   swift /tmp/guest-axpress.swift <pid> <index>    # AXPress extra #index, print the AXError
import ApplicationServices
import Foundation
let args = CommandLine.arguments
guard args.count >= 2, let pid = pid_t(args[1]) else { print("usage: <pid> [index]"); exit(2) }
let app = AXUIElementCreateApplication(pid)
var bar: CFTypeRef?
let err = AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar)
guard err == .success, let bar else { print("no extras menu bar: \(err.rawValue)"); exit(1) }
var kids: CFTypeRef?
AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids)
let children = (kids as? [AXUIElement]) ?? []
for (i, c) in children.enumerated() {
    var pos: CFTypeRef?, title: CFTypeRef?, desc: CFTypeRef?, acts: CFArray?
    AXUIElementCopyAttributeValue(c, kAXPositionAttribute as CFString, &pos)
    AXUIElementCopyAttributeValue(c, kAXTitleAttribute as CFString, &title)
    AXUIElementCopyAttributeValue(c, kAXDescriptionAttribute as CFString, &desc)
    AXUIElementCopyActionNames(c, &acts)
    var p = CGPoint.zero
    if let pos { AXValueGetValue(pos as! AXValue, .cgPoint, &p) }
    print(i, p, title as? String ?? "-", desc as? String ?? "-", (acts as? [String]) ?? [])
}
if args.count >= 3, let i = Int(args[2]), i < children.count {
    AXUIElementSetMessagingTimeout(children[i], 0.25)
    let t0 = Date()
    let r = AXUIElementPerformAction(children[i], kAXPressAction as CFString)
    print("AXPress ->", r.rawValue, "in", Date().timeIntervalSince(t0))
}
