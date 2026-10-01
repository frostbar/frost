// Frost — MenuBarSpike
//
// Gating spike (plan Task 2): verifies on real hardware how hiding (separator length),
// moving (synthesised ⌘-drag), clicking (AXPress vs CGEvent), menu/popover close detection
// and ScreenCaptureKit screenshots behave for NSStatusItems on macOS 26.
//
// SAFETY: this program only ever moves / clicks its OWN status items. Before any synthetic
// mouse-down it verifies that the start point is covered only by the spike's own status windows
// (or, for the window-ID-routing test, that the down point is on another spike item). The cursor
// is restored after every synthetic sequence. All status items and UserDefaults seeds are removed
// on exit, including failure paths, SIGINT/SIGTERM and a 180 s watchdog.
//
// Build & run (from a terminal that has Accessibility + Screen Recording):
//   mkdir -p build && swiftc -swift-version 6 -O Spikes/MenuBarSpike/main.swift -o build/menubar-spike && ./build/menubar-spike
//
// Optional environment:
//   SPIKE_SEEDS="SpikeV=0,SpikeIcon=1,..."  preferred-position seeds ("none" = no seeds)
//   SPIKE_STEPS="1,2,3"                        run only these steps (1 is always run)
//   SPIKE_OUT=/path                            where screenshots are written (default build/spike-out)

import AppKit
import ApplicationServices
import ScreenCaptureKit

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Logging

let spikeStart = Date()
func ms(since d: Date) -> Int { Int(Date().timeIntervalSince(d) * 1000) }
func log(_ s: String) { print(String(format: "[%7.2f] ", Date().timeIntervalSince(spikeStart)) + s) }
func header(_ s: String) { print("\n==================== \(s) ====================") }
func fmt(_ r: CGRect) -> String {
    String(format: "(x:%.1f y:%.1f w:%.1f h:%.1f)", r.origin.x, r.origin.y, r.width, r.height)
}
func fmt(_ p: CGPoint) -> String { String(format: "(%.1f, %.1f)", p.x, p.y) }

// MARK: - Configuration

let env = ProcessInfo.processInfo.environment
let outDir = env["SPIKE_OUT"] ?? FileManager.default.currentDirectoryPath + "/build/spike-out"
let enabledSteps: Set<Int> = {
    guard let s = env["SPIKE_STEPS"] else { return Set(1...8) }
    return Set(s.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }).union([1])
}()

enum Name: String, CaseIterable, Sendable {
    case icon = "SpikeIcon", h = "SpikeH", ah = "SpikeAH", v = "SpikeV", x = "SpikeX", y = "SpikeY"
    var short: String {
        switch self { case .icon: "Icon"; case .h: "H"; case .ah: "AH"; case .v: "V"; case .x: "X"; case .y: "Y" }
    }
    var title: String {
        switch self { case .icon: "❄"; case .h: "|"; case .ah: "‖"; case .v: "V"; case .x: "X"; case .y: "Y" }
    }
}

/// Production creation order (Icon → H → AH), then the test items.
let creationOrder: [Name] = [.icon, .h, .ah, .v, .x, .y]
/// Desired left → right order.
let targetOrder: [Name] = [.y, .ah, .x, .h, .icon, .v]

/// Preferred Position seeds. Bigger value = further left (distance from the right end).
let seeds: [Name: Double] = {
    if env["SPIKE_SEEDS"] == "none" { return [:] }
    if let s = env["SPIKE_SEEDS"] {
        var r: [Name: Double] = [:]
        for pair in s.split(separator: ",") {
            let kv = pair.split(separator: "=")
            if kv.count == 2, let n = Name(rawValue: String(kv[0])), let v = Double(kv[1]) { r[n] = v }
        }
        return r
    }
    // Default guess: small increasing values right → left, V rightmost.
    return [.v: 0, .icon: 1, .h: 2, .x: 3, .ah: 4, .y: 5]
}()

func seedKey(_ n: Name) -> String { "NSStatusItem Preferred Position \(n.rawValue)" }

/// Remove every defaults key the spike (or AppKit on its behalf) wrote. Thread-safe.
func removeSpikeDefaults() {
    let d = UserDefaults.standard
    for key in d.dictionaryRepresentation().keys where key.contains("Spike") { d.removeObject(forKey: key) }
    d.synchronize()
}

// MARK: - Window list helpers

struct Win: Sendable, Equatable {
    let id: CGWindowID
    let layer: Int
    let pid: Int32
    let owner: String
    let title: String
    let frame: CGRect
    let onscreen: Bool
    var desc: String {
        "id=\(id) layer=\(layer) pid=\(pid) owner=\(owner) title=\"\(title)\" frame=\(fmt(frame)) onscreen=\(onscreen)"
    }
}

func windowList(_ options: CGWindowListOption) -> [Win] {
    let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    return raw.compactMap { d in
        guard let n = d[kCGWindowNumber as String] as? Int,
              let b = d[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: b) else { return nil }
        return Win(id: CGWindowID(n), layer: d[kCGWindowLayer as String] as? Int ?? 0,
                   pid: Int32(d[kCGWindowOwnerPID as String] as? Int ?? 0),
                   owner: d[kCGWindowOwnerName as String] as? String ?? "",
                   title: d[kCGWindowName as String] as? String ?? "",
                   frame: frame, onscreen: (d[kCGWindowIsOnscreen as String] as? Bool) ?? false)
    }
}
func statusWindows() -> [Win] { windowList(.optionAll).filter { $0.layer == 25 } }

func displays() -> [(id: CGDirectDisplayID, bounds: CGRect)] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n)
    return (0..<Int(n)).map { (ids[$0], CGDisplayBounds(ids[$0])) }
}
let mainBounds = CGDisplayBounds(CGMainDisplayID())

func cursorLocation() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

// MARK: - Event synthesis (runs off the main thread so our own run loop can process events)

let field0x33 = CGEventField(rawValue: 0x33)!   // Ice: "windowID" field

struct DragVariant: Sendable {
    var name: String
    var tap: CGEventTapLocation = .cgSessionEventTap
    var windowUnderPointer = true          // .mouseEventWindowUnderMousePointer
    var windowThatCanHandle = true         // .mouseEventWindowUnderMousePointerThatCanHandleThisEvent
    var iceFields = false                  // 0x33 + eventTargetUnixProcessID
    var warpFirst = false
    var draggedSteps = true
    var upUsesTargetWindow = false         // mouseUp carries the destination item's window ID (Ice)
    var postToPid: pid_t? = nil            // additionally postToPid before tap (Ice "scromble"-ish)
    var targetPIDField = true              // with iceFields: also set eventTargetUnixProcessID
}

nonisolated(unsafe) var savedCursorForCleanup: CGPoint? = nil

/// Posts a ⌘-drag. `windowID` is the dragged item's window; `targetWindowID` the destination item.
func postDrag(_ v: DragVariant, windowID: CGWindowID, targetWindowID: CGWindowID,
              targetPID: pid_t, from start: CGPoint, to end: CGPoint) {
    let src = CGEventSource(stateID: .hidSystemState)
    // Ice: allow our events during suppression states.
    if let s = CGEventSource(stateID: .combinedSessionState) {
        let permit: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
        s.setLocalEventsFilterDuringSuppressionState(permit, state: .eventSuppressionStateRemoteMouseDrag)
        s.setLocalEventsFilterDuringSuppressionState(permit, state: .eventSuppressionStateSuppressionInterval)
        s.localEventsSuppressionInterval = 0
    }
    let saved = cursorLocation()
    func ev(_ type: CGEventType, _ p: CGPoint, win: CGWindowID) -> CGEvent {
        let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)!
        e.flags = .maskCommand
        if v.windowUnderPointer { e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(win)) }
        if v.windowThatCanHandle {
            e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(win))
        }
        if v.iceFields {
            e.setIntegerValueField(field0x33, value: Int64(win))
            if v.targetPIDField { e.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(targetPID)) }
        }
        return e
    }
    func post(_ e: CGEvent) {
        if let pid = v.postToPid { e.postToPid(pid); usleep(5_000) }
        e.post(tap: v.tap)
    }
    if v.warpFirst { CGWarpMouseCursorPosition(start); usleep(20_000) }
    post(ev(.leftMouseDown, start, win: windowID))
    usleep(50_000)
    if v.draggedSteps {
        for i in 1...10 {
            let t = CGFloat(i) / 10
            post(ev(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y), win: windowID))
            usleep(15_000)
        }
    }
    post(ev(.leftMouseUp, end, win: v.upUsesTargetWindow ? targetWindowID : windowID))
    usleep(20_000)
    CGWarpMouseCursorPosition(saved)
}

func postClick(at p: CGPoint, windowID: CGWindowID, withFields: Bool) {
    let src = CGEventSource(stateID: .hidSystemState)
    let saved = cursorLocation()
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)!
        e.flags = []
        e.setIntegerValueField(.mouseEventClickState, value: 1)
        if withFields {
            e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
            e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
        }
        e.post(tap: .cgSessionEventTap)
        usleep(30_000)
    }
    CGWarpMouseCursorPosition(saved)
}

// MARK: - Accessibility helpers (off main thread: AX calls into our own process would otherwise deadlock)

struct AXItem: Sendable { let frame: CGRect; let desc: String; let title: String; let ident: String }

func axExtras(pid: pid_t) -> (items: [AXItem], error: Int32) {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 3)
    var v: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(app, kAXExtrasMenuBarAttribute as CFString, &v)
    guard err == .success, let bar = v else { return ([], err.rawValue) }
    var c: CFTypeRef?
    AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &c)
    let children = c as? [AXUIElement] ?? []
    return (children.map(axItem), 0)
}

func axItem(_ e: AXUIElement) -> AXItem {
    func str(_ a: String) -> String {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(e, a as CFString, &v)
        return v as? String ?? ""
    }
    var pv: CFTypeRef?, sv: CFTypeRef?
    var p = CGPoint.zero, s = CGSize.zero
    if AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pv) == .success, let pv {
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
    }
    if AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &sv) == .success, let sv {
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
    }
    return AXItem(frame: CGRect(origin: p, size: s), desc: str(kAXDescriptionAttribute),
                  title: str(kAXTitleAttribute), ident: str(kAXIdentifierAttribute))
}

/// AXPress the extras child of `pid` whose midX is within 4pt of `midX`.
func axPress(pid: pid_t, midX: CGFloat) -> String {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 5)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXExtrasMenuBarAttribute as CFString, &v) == .success, let bar = v
    else { return "no extras menu bar" }
    var c: CFTypeRef?
    AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &c)
    let children = c as? [AXUIElement] ?? []
    guard let child = children.first(where: { abs(axItem($0).frame.midX - midX) <= 4 }) else {
        return "no child near midX=\(midX) (children: \(children.map { fmt(axItem($0).frame) }))"
    }
    var names: CFArray?
    AXUIElementCopyActionNames(child, &names)
    let t = Date()
    let err = AXUIElementPerformAction(child, kAXPressAction as CFString)
    return "actions=\(names as? [String] ?? []) AXPress err=\(err.rawValue) returned after \(ms(since: t)) ms"
}

// MARK: - New-window poller (off main thread so it keeps running during menu tracking)

struct SeenWindow: Sendable { var win: Win; var firstMs: Int; var lastMs: Int }

func pollNewWindows(baseline: Set<CGWindowID>, durationMs: Int, intervalMs: Int = 100) async -> [SeenWindow] {
    await Task.detached {
        var seen: [CGWindowID: SeenWindow] = [:]
        let start = Date()
        while ms(since: start) < durationMs {
            let now = ms(since: start)
            for w in windowList([.optionOnScreenOnly]) where !baseline.contains(w.id) {
                if var s = seen[w.id] {
                    s.lastMs = now
                    // keep the largest frame seen (popover windows shrink to 1×1 while closing)
                    if w.frame.width * w.frame.height > s.win.frame.width * s.win.frame.height { s.win = w }
                    seen[w.id] = s
                }
                else { seen[w.id] = SeenWindow(win: w, firstMs: now, lastMs: now) }
            }
            usleep(useconds_t(intervalMs * 1000))
        }
        return seen.values.sorted { $0.firstMs < $1.firstMs }
    }.value
}

// MARK: - Spike

enum SectionState: String { case collapsed, expanded, expandedAll, editing }

@MainActor final class Spike: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    var items: [Name: NSStatusItem] = [:]
    var ids: [Name: CGWindowID] = [:]
    var replicaIDs: Set<CGWindowID> = []
    var baselineStatusIDs: Set<CGWindowID> = []
    let menu = NSMenu()
    let popover = NSPopover()
    var menuOpenedAt: Date?
    var events: [String] = []
    var workingVariant: DragVariant?
    var cleanedUp = false
    let pid = getpid()

    func applicationDidFinishLaunching(_ n: Notification) {
        savedCursorForCleanup = cursorLocation()
        installSafetyNets()
        Task { @MainActor in
            defer { cleanup(); NSApp.terminate(nil) }
            await runAllSteps()
        }
    }

    // MARK: safety

    func installSafetyNets() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
            MainActor.assumeIsolated {
                log("WATCHDOG fired after 180 s — cleaning up and exiting")
                self.cleanup()
            }
            exit(3)
        }
        // Last-resort watchdog in case the main thread is wedged.
        Thread.detachNewThread {
            sleep(195)
            removeSpikeDefaults()
            if let p = savedCursorForCleanup { CGWarpMouseCursorPosition(p) }
            print("HARD WATCHDOG: main thread unresponsive, exiting")
            exit(4)
        }
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                MainActor.assumeIsolated {
                    log("signal \(sig) — cleaning up")
                    self.cleanup()
                }
                exit(5)
            }
            src.resume()
            signalSources.append(src)
        }
    }
    var signalSources: [DispatchSourceSignal] = []

    func cleanup() {
        guard !cleanedUp else { return }
        cleanedUp = true
        if popover.isShown { popover.close() }
        menu.cancelTrackingWithoutAnimation()
        let before = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.contains("Spike") }
        for (_, item) in items { NSStatusBar.system.removeStatusItem(item) }
        items.removeAll()
        let afterRemove = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.contains("Spike") }
        removeSpikeDefaults()
        let afterClean = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.contains("Spike") }
        if let p = savedCursorForCleanup { CGWarpMouseCursorPosition(p) }
        header("CLEANUP")
        log("defaults before removeStatusItem: \(before)")
        log("defaults after removeStatusItem (before explicit delete): \(afterRemove)")
        log("defaults after explicit delete: \(afterClean.count) keys")
        log("cursor restored to \(savedCursorForCleanup.map(fmt) ?? "nil"); status items removed")
    }

    // MARK: menu / popover delegates

    func menuWillOpen(_ menu: NSMenu) { menuOpenedAt = Date(); events.append("menuWillOpen"); log("  [delegate] X menuWillOpen") }
    func menuDidClose(_ menu: NSMenu) {
        events.append("menuDidClose")
        log("  [delegate] X menuDidClose (open for \(menuOpenedAt.map { ms(since: $0) } ?? -1) ms)")
    }
    func popoverDidShow(_ n: Notification) {
        events.append("popoverDidShow")
        let w = popover.contentViewController?.view.window
        let wn = w?.windowNumber ?? 0
        let cg = windowList(.optionAll).first { Int($0.id) == wn }
        log("  [delegate] Y popoverDidShow; popover NSWindow number=\(wn) level=\(w?.level.rawValue ?? -1) frame(CG)=\(w.map { fmt(cgFrame(ofAppKit: $0.frame)) } ?? "nil") | CGWindowList entry: \(cg?.desc ?? "NOT FOUND")")
        let mine = windowList(.optionAll).filter { $0.pid == pid }
        for m in mine { log("    own-pid window: \(m.desc)") }
    }
    func popoverDidClose(_ n: Notification) { events.append("popoverDidClose"); log("  [delegate] Y popoverDidClose") }

    @objc func yClicked(_ sender: Any?) {
        events.append("yAction")
        log("  [action] Y button action fired (currentEvent=\(NSApp.currentEvent?.type.rawValue ?? 0))")
        guard let button = items[.y]?.button else { return }
        if popover.isShown { popover.performClose(nil) } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
    @objc func hello(_ sender: Any?) { log("  [action] Hello chosen") }

    // MARK: scanning

    func cgFrame(ofAppKit r: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: r.minX, y: top - r.maxY, width: r.width, height: r.height)
    }

    func snapshot() -> [Name: Win] {
        let st = Dictionary(statusWindows().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var r: [Name: Win] = [:]
        for (n, id) in ids { if let w = st[id] { r[n] = w } }
        return r
    }

    func orderString(_ snap: [Name: Win]) -> String {
        snap.sorted { $0.value.frame.minX < $1.value.frame.minX }.map { "[\($0.key.short)]" }.joined()
    }
    func order(_ snap: [Name: Win]) -> [Name] { snap.sorted { $0.value.frame.minX < $1.value.frame.minX }.map(\.key) }

    func printSnapshot(_ snap: [Name: Win], indent: String = "  ") {
        for n in order(snap) {
            let w = snap[n]!
            let onMain = mainBounds.contains(CGPoint(x: w.frame.midX, y: w.frame.midY))
            let other = displays().first { $0.id != CGMainDisplayID() && $0.bounds.contains(CGPoint(x: w.frame.midX, y: w.frame.midY)) }
            let appKit = items[n]?.button?.window.map { cgFrame(ofAppKit: $0.frame) } ?? .null
            log("\(indent)\(n.short.padding(toLength: 4, withPad: " ", startingAt: 0)) id=\(w.id) cg=\(fmt(w.frame)) onscreen=\(w.onscreen) inMainDisplay=\(onMain)\(other.map { " IN-OTHER-DISPLAY(\($0.id))" } ?? "") nsWindow=\(fmt(appKit)) len=\(items[n]!.length)")
        }
        log("\(indent)order: \(orderString(snap))")
    }

    func printReplicas() {
        let st = statusWindows().filter { replicaIDs.contains($0.id) }.sorted { $0.frame.minX < $1.frame.minX }
        for w in st { log("    replica \(w.desc)") }
    }

    // MARK: states

    func setState(_ s: SectionState) {
        let (h, ah): (CGFloat, CGFloat) = switch s {
        case .collapsed: (10_000, 10_000)
        case .expanded: (0, 10_000)
        case .expandedAll: (0, 0)
        case .editing: (8, 8)
        }
        items[.h]?.length = h
        items[.ah]?.length = ah
    }

    /// Switch state and poll every 50 ms for 2 s. Returns (lastChangeMs, firstStableMs).
    @discardableResult
    func switchState(_ s: SectionState, pollMs: Int = 2000, quiet: Bool = false) async -> (Int, Int?) {
        let before = snapshot()
        setState(s)
        let start = Date()
        var last = before
        var lastChange = 0
        var firstStableAfterChange: Int? = nil
        var changed = false
        var at500: [Name: Win]? = nil
        while ms(since: start) < pollMs {
            try? await Task.sleep(for: .milliseconds(50))
            let cur = snapshot()
            let now = ms(since: start)
            if cur.mapValues(\.frame) != last.mapValues(\.frame) {
                lastChange = now; changed = true; firstStableAfterChange = nil
            } else if changed && firstStableAfterChange == nil {
                firstStableAfterChange = now
            }
            if at500 == nil && now >= 500 { at500 = cur }
            last = cur
        }
        if !quiet {
            log("state=\(s.rawValue): H.len=\(items[.h]!.length) AH.len=\(items[.ah]!.length); frames changed=\(changed), last change at \(lastChange) ms, first 2 equal scans after change at \(firstStableAfterChange.map(String.init) ?? "n/a") ms")
            if let at500 {
                log("  scan @500ms:")
                printSnapshot(at500, indent: "    ")
                log("  @500ms == final? \(at500.mapValues(\.frame) == last.mapValues(\.frame))")
            }
            let idsSame = Set(last.values.map(\.id)) == Set(ids.values)
            log("  all 6 windowIDs still enumerable in CGWindowList: \(last.count == 6 && idsSame)")
        }
        return (lastChange, firstStableAfterChange)
    }

    /// Poll every 25 ms: when did ANY spike frame first change, when did `satisfied` first hold, and
    /// when were all frames stable for 2 consecutive polls (≥ 50 ms) after the first change.
    func waitForFrameChange(_ n: Name, from: CGRect, timeoutMs: Int = 2000,
                            satisfied: (([Name]) -> Bool)? = nil) async -> (changedMs: Int?, stableMs: Int?, satisfiedMs: Int?) {
        let start = Date()
        var changedMs: Int? = nil
        var satisfiedMs: Int? = nil
        let initial = snapshot().mapValues(\.frame)
        var prevAll = initial
        var stableCount = 0
        while ms(since: start) < timeoutMs {
            try? await Task.sleep(for: .milliseconds(25))
            let snap = snapshot()
            let s = snap.mapValues(\.frame)
            if changedMs == nil, s != initial { changedMs = ms(since: start) }
            if satisfiedMs == nil, let satisfied, satisfied(order(snap)) { satisfiedMs = ms(since: start) }
            if changedMs != nil {
                if s == prevAll { stableCount += 1; if stableCount >= 2 { return (changedMs, ms(since: start), satisfiedMs) } }
                else { stableCount = 0 }
            }
            prevAll = s
        }
        return (changedMs, nil, satisfiedMs)
    }

    func isSatisfied(_ o: [Name], _ n: Name, rightOf: Name?, leftOf: Name?) -> Bool {
        guard let i = o.firstIndex(of: n) else { return false }
        if let r = rightOf { return i > 0 && o[i - 1] == r }
        if let l = leftOf { return i + 1 < o.count && o[i + 1] == l }
        return false
    }

    // MARK: safety check for synthetic mouse-downs

    /// True if every on-screen status window containing `p` is one of the spike's own windows and there is at least one.
    func pointIsOnSpikeItem(_ p: CGPoint, expect: Name) -> Bool {
        let own = Set(ids.values).union(replicaIDs)
        let hits = windowList([.optionOnScreenOnly]).filter { $0.frame.contains(p) && $0.layer >= 25 && $0.layer < 1000 }
        let statusHits = hits.filter { $0.layer == 25 }
        let ok = !statusHits.isEmpty && statusHits.allSatisfy { own.contains($0.id) } && statusHits.first?.id == ids[expect]
        if !ok { log("  SAFETY: point \(fmt(p)) hits \(hits.map(\.desc)) — expected spike item \(expect.short) id=\(ids[expect] ?? 0); refusing") }
        return ok
    }

    // MARK: steps

    func runAllSteps() async {
        header("ENVIRONMENT")
        log("macOS \(ProcessInfo.processInfo.operatingSystemVersionString); pid=\(pid); bundleID=\(Bundle.main.bundleIdentifier ?? "nil"); process=\(ProcessInfo.processInfo.processName)")
        log("AXIsProcessTrusted=\(AXIsProcessTrusted()) CGPreflightScreenCaptureAccess=\(CGPreflightScreenCaptureAccess())")
        for d in displays() { log("display \(d.id) bounds=\(fmt(d.bounds))\(d.id == CGMainDisplayID() ? " MAIN" : "")") }
        for s in NSScreen.screens {
            log("NSScreen \(s.localizedName) frame=\(fmt(s.frame)) safeTop=\(s.safeAreaInsets.top) auxL=\(fmt(s.auxiliaryTopLeftArea ?? .zero)) auxR=\(fmt(s.auxiliaryTopRightArea ?? .zero))")
        }
        log("status bar thickness=\(NSStatusBar.system.thickness); steps=\(enabledSteps.sorted())")
        log("cursor at start: \(fmt(cursorLocation()))")

        await step1()
        guard ids.count == 6 else { log("ABORT: could not resolve CG window IDs for all 6 items"); return }
        if enabledSteps.contains(2) { await step2(); await step2b() }
        if enabledSteps.contains(3) { await step3() }
        if enabledSteps.contains(4) { await step4() }
        if enabledSteps.contains(5) { await step5() }
        if enabledSteps.contains(6) || enabledSteps.contains(7) { await step6and7() }
        if enabledSteps.contains(8) { await step8() }
        header("DONE")
    }

    // Step 1 ------------------------------------------------------------------------------------

    func step1() async {
        header("STEP 1: create items, seeds, windowNumber vs CGWindowList")
        removeSpikeDefaults()
        for (n, v) in seeds { UserDefaults.standard.set(v, forKey: seedKey(n)) }
        log("seeds written: \(seeds.sorted { $0.value < $1.value }.map { "\($0.key.short)=\($0.value)" }.joined(separator: " "))")
        baselineStatusIDs = Set(statusWindows().map(\.id))

        let xm = NSMenuItem(title: "Hello", action: #selector(hello(_:)), keyEquivalent: "")
        xm.target = self
        menu.addItem(xm)
        menu.delegate = self
        let vc = NSViewController()
        let label = NSTextField(labelWithString: "Hello popover")
        label.frame = NSRect(x: 20, y: 30, width: 160, height: 20)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        content.addSubview(label)
        vc.view = content
        popover.contentViewController = vc
        popover.behavior = .applicationDefined
        popover.delegate = self

        for n in creationOrder {
            let len: CGFloat = (n == .h || n == .ah) ? 8 : NSStatusItem.variableLength
            let item = NSStatusBar.system.statusItem(withLength: len)
            item.autosaveName = n.rawValue
            item.button?.title = n.title
            if n == .x { item.menu = menu }
            if n == .y {
                item.button?.target = self
                item.button?.action = #selector(yClicked(_:))
                item.button?.sendAction(on: [.leftMouseUp])
            }
            items[n] = item
            log("created \(n.rawValue) (\(n.title)) len=\(len) windowNumber=\(item.button?.window?.windowNumber ?? -1)")
        }
        try? await Task.sleep(for: .milliseconds(1000))

        let st = statusWindows()
        let newWins = st.filter { !baselineStatusIDs.contains($0.id) }
        log("new layer-25 windows after creation: \(newWins.count)")
        for w in newWins.sorted(by: { $0.frame.minX < $1.frame.minX }) { log("  \(w.desc)") }

        for n in creationOrder {
            let item = items[n]!
            let rawWN = item.button?.window?.windowNumber ?? 0
            let wn = CGWindowID(truncatingIfNeeded: rawWN)
            let byNumber = rawWN > 0 && rawWN <= Int(UInt32.max) ? st.first { $0.id == wn } : nil
            let byTitle = st.filter { $0.title == n.rawValue }
            let nsFrame = item.button?.window.map { cgFrame(ofAppKit: $0.frame) } ?? .null
            let byFrame = newWins.filter { abs($0.frame.minX - nsFrame.minX) < 1 && abs($0.frame.width - nsFrame.width) < 1 }
            log("\(n.short): windowNumber=\(rawWN) (hex 0x\(String(rawWN, radix: 16))) inCGList=\(byNumber != nil) \(byNumber.map { "(owner=\($0.owner) pid=\($0.pid) title=\"\($0.title)\")" } ?? "") | titleMatches=\(byTitle.map(\.id)) | nsWindowFrame=\(fmt(nsFrame)) frameMatches=\(byFrame.map(\.id)) | screen=\(item.button?.window?.screen?.localizedName ?? "nil")")
            if byNumber != nil { ids[n] = wn } else if byTitle.count == 1 { ids[n] = byTitle[0].id }
        }
        replicaIDs = Set(newWins.map(\.id)).subtracting(ids.values)
        log("replica windows (other displays): \(replicaIDs.sorted())")
        printReplicas()

        let prefs = creationOrder.map { n in "\(n.short)=\(UserDefaults.standard.object(forKey: seedKey(n)) ?? "nil")" }
        log("Preferred Position values after creation: \(prefs.joined(separator: " "))")
        let otherKeys = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.contains("Spike") && !$0.key.contains("Preferred Position") }
        log("other Spike defaults keys: \(otherKeys)")

        let snap = snapshot()
        printSnapshot(snap)
        let got = order(snap)
        log("target order: \(targetOrder.map { "[\($0.short)]" }.joined())  achieved=\(got == targetOrder)")

        // AX view of our own extras
        let pid = self.pid
        let ax = await Task.detached { axExtras(pid: pid) }.value
        log("AX extras of own pid: error=\(ax.error) children=\(ax.items.count)")
        for a in ax.items.sorted(by: { $0.frame.minX < $1.frame.minX }) {
            let match = snap.first { abs($0.value.frame.midX - a.frame.midX) <= 4 }
            log("  AX frame=\(fmt(a.frame)) desc=\"\(a.desc)\" title=\"\(a.title)\" id=\"\(a.ident)\" → matches \(match?.key.short ?? "none") (cg midX \(match.map { String(format: "%.1f", $0.value.frame.midX) } ?? "-"))")
        }
    }

    // Step 2 ------------------------------------------------------------------------------------

    func step2() async {
        header("STEP 2: section states (0.5 s scan, 50 ms settle polling)")
        for s: SectionState in [.collapsed, .expanded, .expandedAll, .editing, .collapsed, .expandedAll] {
            await switchState(s)
            let snap = snapshot()
            log("  final order: \(orderString(snap)) (target \(targetOrder.map { "[\($0.short)]" }.joined()))")
            if s == .collapsed, let icon = snap[.icon] {
                // Does the 5016-pt-wide separator window swallow clicks on app menus / the empty bar?
                let pts = [CGPoint(x: 300, y: 19), CGPoint(x: icon.frame.minX - 60, y: 19)]
                for p in pts {
                    let top = windowList([.optionOnScreenOnly]).first { $0.frame.contains(p) && $0.layer < 1000 }
                    let hit = await Task.detached { () -> String in
                        let sys = AXUIElementCreateSystemWide()
                        var el: AXUIElement?
                        let err = AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &el)
                        guard err == .success, let el else { return "AX err \(err.rawValue)" }
                        var pid: pid_t = 0; AXUIElementGetPid(el, &pid)
                        var role: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
                        let a = axItem(el)
                        return "pid=\(pid) \(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?") role=\(role as? String ?? "") title=\"\(a.title)\" desc=\"\(a.desc)\""
                    }.value
                    log("  hit-test \(fmt(p)) in collapsed: topmost CG window=\(top?.desc ?? "none") | AX element: \(hit)")
                }
            }
            printReplicas()
            // AX view in this state
            let pid = self.pid
            let ax = await Task.detached { axExtras(pid: pid) }.value
            log("  AX children: \(ax.items.sorted { $0.frame.minX < $1.frame.minX }.map { "\($0.desc.isEmpty ? $0.title : $0.desc)@\(fmt($0.frame))" })")
        }
    }

    /// 2b: can a separator be truly zero-width? (length 0 leaves a 16 pt window)
    func step2b() async {
        header("STEP 2b: zero-width separator variants (expanded state, H only)")
        await switchState(.expanded, pollMs: 500, quiet: true)
        guard let h = items[.h], let button = h.button else { return }
        func report(_ label: String) async {
            try? await Task.sleep(for: .milliseconds(300))
            let snap = snapshot()
            let w = snap[.h]
            log("  [\(label)] H cg=\(w.map { fmt($0.frame) } ?? "NOT ENUMERABLE") onscreen=\(w?.onscreen ?? false) len=\(h.length) isVisible=\(h.isVisible) | X.maxX=\(snap[.x].map { String(format: "%.1f", $0.frame.maxX) } ?? "-") Icon.minX=\(snap[.icon].map { String(format: "%.1f", $0.frame.minX) } ?? "-") order=\(orderString(snap))")
        }
        await report("length 0, title \"|\"")
        let savedTitle = button.title
        button.title = ""
        await report("length 0, title \"\"")
        button.title = savedTitle
        // Ice hack: deactivate the content-view constraint that pins the button, shrink the window to 1 pt.
        let constraints = button.window?.contentView?.constraintsAffectingLayout(for: .horizontal) ?? []
        let cands = constraints.filter { $0.secondItem === button.superview }
        log("  horizontal constraints on H content view: \(constraints.count); Ice-predicate matches: \(cands.count) \(cands.map { "\($0)" })")
        if let c = cands.first {
            c.isActive = false
            if let win = button.window { var sz = win.frame.size; sz.width = 1; win.setContentSize(sz) }
            await report("Ice hack: constraint off + content width 1")
            c.isActive = true
            h.length = 8; h.length = 0
            await report("constraint restored, length 0")
        }
    }

    // Step 3 ------------------------------------------------------------------------------------

    func capture(_ n: Name, label: String) async {
        guard let id = ids[n] else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let w = content.windows.first(where: { $0.windowID == id }) else {
                log("  [\(label)] window \(id) NOT in SCShareableContent (\(content.windows.filter { $0.windowLayer == 25 }.count) layer-25 windows listed)")
                return
            }
            log("  [\(label)] SCWindow frame=\(fmt(w.frame)) onScreen=\(w.isOnScreen) layer=\(w.windowLayer) owner=\(w.owningApplication?.applicationName ?? "nil")")
            let cfg = SCStreamConfiguration()
            cfg.width = max(1, Int(w.frame.width * 2))
            cfg.height = max(1, Int(w.frame.height * 2))
            cfg.showsCursor = false
            cfg.ignoreShadowsSingleWindow = true
            let t = Date()
            let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg)
            let (opaque, total) = alphaCount(img)
            let path = "\(outDir)/X-\(label).png"
            savePNG(img, path)
            log("  [\(label)] captured \(img.width)x\(img.height) px in \(ms(since: t)) ms; alpha>128 pixels: \(opaque)/\(total); saved \(path)")
        } catch {
            log("  [\(label)] capture FAILED: \(error)")
        }
    }

    /// CGWindowListCreateImage is unavailable in the macOS 15+ SDK; call it through dlsym just to learn
    /// whether the window server can still render an off-screen status window.
    func legacyCapture(_ n: Name, label: String) {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let h = dlopen(nil, RTLD_NOW), let sym = dlsym(h, "CGWindowListCreateImage"), let id = ids[n] else {
            log("  [\(label)] symbol not found"); return
        }
        let fn = unsafeBitCast(sym, to: Fn.self)
        // kCGWindowListOptionIncludingWindow = 1<<3, kCGWindowImageBoundsIgnoreFraming = 1<<0
        if let img = fn(.null, 1 << 3, id, 1 << 0)?.takeRetainedValue() {
            let (o, t) = alphaCount(img)
            savePNG(img, "\(outDir)/X-\(label).png")
            log("  [\(label)] got \(img.width)x\(img.height) px, alpha>128: \(o)/\(t)")
        } else {
            log("  [\(label)] returned nil")
        }
    }

    func alphaCount(_ img: CGImage) -> (Int, Int) {
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (0, 0) }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var n = 0
        for i in stride(from: 3, to: px.count, by: 4) where px[i] > 128 { n += 1 }
        return (n, w * h)
    }

    func savePNG(_ img: CGImage, _ path: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    func step3() async {
        header("STEP 3: ScreenCaptureKit capture of X (visible / pushed off-screen / restored)")
        await switchState(.expanded, pollMs: 700, quiet: true)
        log("  X frame (expanded): \(snapshot()[.x].map { fmt($0.frame) } ?? "?")")
        await capture(.x, label: "a-visible")
        await switchState(.collapsed, pollMs: 700, quiet: true)
        log("  X frame (collapsed): \(snapshot()[.x].map { "\(fmt($0.frame)) onscreen=\($0.onscreen)" } ?? "?")")
        await capture(.x, label: "b-offscreen")
        legacyCapture(.x, label: "b-offscreen-CGWindowListCreateImage")
        await switchState(.expanded, pollMs: 700, quiet: true)
        await capture(.x, label: "c-restored")
        // also capture a control item and V for reference
        await capture(.v, label: "V-visible")
    }

    // Step 4 ------------------------------------------------------------------------------------

    func cgPID(of n: Name) -> pid_t { pid_t(snapshot()[n]?.pid ?? 0) }

    /// Moves `n` to the right/left of `target` with `variant`. Returns success.
    func tryMove(_ n: Name, rightOf: Name? = nil, leftOf: Name? = nil, variant v: DragVariant,
                 startOverride: (Name, CGPoint)? = nil, endOverride: CGPoint? = nil, label: String) async -> Bool {
        let snap = snapshot()
        guard let item = snap[n], let t = snap[rightOf ?? leftOf!] else { log("  missing frames"); return false }
        let tName = (rightOf ?? leftOf)!
        let start = startOverride?.1 ?? CGPoint(x: item.frame.midX, y: item.frame.midY)
        let startOwner = startOverride?.0 ?? n
        let end = endOverride ?? (rightOf != nil ? CGPoint(x: t.frame.maxX - 1, y: t.frame.midY)
                                                 : CGPoint(x: t.frame.minX + 1, y: t.frame.midY))
        guard pointIsOnSpikeItem(start, expect: startOwner) else { return false }
        let before = orderString(snap)
        let cursorBefore = cursorLocation()
        let dragID = ids[n]!, targetID = ids[tName]!, tpid = pid_t(item.pid)
        let t0 = Date()
        await Task.detached { postDrag(v, windowID: dragID, targetWindowID: targetID, targetPID: tpid, from: start, to: end) }.value
        let postMs = ms(since: t0)
        let (changedMs, stableMs, satMs) = await waitForFrameChange(n, from: item.frame) {
            self.isSatisfied($0, n, rightOf: rightOf, leftOf: leftOf)
        }
        let after = snapshot()
        let ok = isSatisfied(order(after), n, rightOf: rightOf, leftOf: leftOf)
        let cursorAfter = cursorLocation()
        log("  [\(label)] variant=\(v.name) \(n.short) \(rightOf != nil ? "rightOf" : "leftOf") \(tName.short): start=\(fmt(start)) end=\(fmt(end)) | \(before) → \(orderString(after)) | SUCCESS=\(ok) | events took \(postMs) ms; after last event: first frame change \(changedMs.map { "\($0) ms" } ?? "never"), order satisfied \(satMs.map { "\($0) ms" } ?? "never"), all frames stable \(stableMs.map { "\($0) ms" } ?? "n/a") | cursor \(fmt(cursorBefore))→\(fmt(cursorAfter))")
        if !ok, changedMs != nil { printSnapshot(after, indent: "      ") }
        return ok
    }

    let variants: [DragVariant] = [
        DragVariant(name: "plan(session,fields,drag)"),
        DragVariant(name: "plan+warpFirst", warpFirst: true),
        DragVariant(name: "noWindowUnderPointerField", windowUnderPointer: false),
        DragVariant(name: "noWindowFields", windowUnderPointer: false, windowThatCanHandle: false),
        DragVariant(name: "hidTap", tap: .cghidEventTap),
        DragVariant(name: "ice(down→up,0x33,upTargetWin)", iceFields: true, draggedSteps: false, upUsesTargetWindow: true),
    ]

    func step4() async {
        header("STEP 4: on-screen ⌘-drag moves (expandedAll)")
        await switchState(.expandedAll, pollMs: 700, quiet: true)
        printSnapshot(snapshot())
        for v in variants where env["SPIKE_MATRIX"] != "0" || v.name == variants[0].name {
            await switchState(.expandedAll, pollMs: 300, quiet: true)
            let a = await tryMove(.x, rightOf: .icon, variant: v, label: "4a")
            try? await Task.sleep(for: .milliseconds(300))
            if a {
                if workingVariant == nil { workingVariant = v }
                // Back: left of H. H has length 0 in expandedAll — record what happens.
                let b = await tryMove(.x, leftOf: .h, variant: v, label: "4b-expandedAll(H.len=0)")
                if !b {
                    // Retry with H visible (editing, length 8)
                    await switchState(.editing, pollMs: 500, quiet: true)
                    let c = await tryMove(.x, leftOf: .h, variant: v, label: "4b-editing(H.len=8)")
                    if !c { await restoreOrder(using: v) }
                }
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        log("working variant (first): \(workingVariant?.name ?? "NONE")")
        await switchState(.expandedAll, pollMs: 500, quiet: true)
        log("  order after step 4: \(orderString(snapshot()))")

        // Does routing follow the window-ID fields or the location? Start the drag on Y (own item,
        // far left) with X's window ID in the fields, drop right of Icon.
        // Location routing → Y ends right of Icon; window-ID routing → X ends right of Icon.
        let routingVariants: [DragVariant] = [
            variants[0],
            variants.last!,
            DragVariant(name: "ice-without-0x33", iceFields: false, draggedSteps: false, upUsesTargetWindow: true),
            DragVariant(name: "ice+draggedSteps", iceFields: true, draggedSteps: true, upUsesTargetWindow: true),
            DragVariant(name: "ice-upOwnWindow", iceFields: true, draggedSteps: false, upUsesTargetWindow: false),
            DragVariant(name: "0x33-only(no pid field)+plan-drag", iceFields: true, targetPIDField: false),
        ]
        guard env["SPIKE_ROUTING"] != "0" else { return }
        for rv in routingVariants {
            await restoreOrder(using: variants[0])
            await switchState(.editing, pollMs: 400, quiet: true)
            let snap = snapshot()
            let yCenter = CGPoint(x: snap[.y]!.frame.midX, y: snap[.y]!.frame.midY)
            let xMoved = await tryMove(.x, rightOf: .icon, variant: rv, startOverride: (.y, yCenter),
                                       label: "4c routing test (down on Y, fields=X)")
            let yMoved = isSatisfied(order(snapshot()), .y, rightOf: .icon, leftOf: nil)
            log("  ROUTING \(rv.name): X moved=\(xMoved) (window-ID routing); Y moved=\(yMoved) (location routing)")
        }
        await restoreOrder(using: variants[0])
    }

    /// Put everything back into target order using the working variant in editing state.
    func restoreOrder(using v: DragVariant) async {
        await switchState(.editing, pollMs: 500, quiet: true)
        var o = order(snapshot())
        if o == targetOrder { return }
        log("  restoring order from \(orderString(snapshot()))")
        // Place V right of Icon, X left of H, Y left of AH.
        if o.last != .v { _ = await tryMove(.v, rightOf: .icon, variant: v, label: "restore V") }
        o = order(snapshot())
        if let i = o.firstIndex(of: .x), !(i + 1 < o.count && o[i + 1] == .h) {
            _ = await tryMove(.x, leftOf: .h, variant: v, label: "restore X")
        }
        o = order(snapshot())
        if let i = o.firstIndex(of: .y), !(i + 1 < o.count && o[i + 1] == .ah) {
            _ = await tryMove(.y, leftOf: .ah, variant: v, label: "restore Y")
        }
        log("  order now \(orderString(snapshot())) (target achieved=\(order(snapshot()) == targetOrder))")
    }

    // Step 5 ------------------------------------------------------------------------------------

    func step5() async {
        header("STEP 5: off-screen moves (collapsed)")
        let plan = variants[0], ice = variants.last!
        await switchState(.editing, pollMs: 500, quiet: true)
        if order(snapshot()) != targetOrder { await restoreOrder(using: plan) }
        await switchState(.collapsed, pollMs: 700, quiet: true)
        var snap = snapshot()
        printSnapshot(snap)
        let x = snap[.x]!
        let xCenter = CGPoint(x: x.frame.midX, y: x.frame.midY)

        // 5a: raw off-screen start point — only check where the cursor would be clamped to.
        let saved = cursorLocation()
        CGWarpMouseCursorPosition(xCenter)
        try? await Task.sleep(for: .milliseconds(50))
        let clamped = cursorLocation()
        CGWarpMouseCursorPosition(saved)
        let hits = windowList([.optionOnScreenOnly]).filter { $0.frame.contains(clamped) && $0.layer > 0 && $0.layer < 1000 }
        log("  5a: X centre \(fmt(xCenter)) is off every display; warping there puts the cursor at \(fmt(clamped)); windows there: \(hits.map { "\($0.owner)/\($0.title)/layer\($0.layer)" })")
        log("  5a: NOT posting a mouse-down at the raw off-screen point (it is clamped onto other UI) → location-routed off-screen drag is infeasible/unsafe")

        // 5b: off-screen → on-screen, Ice-style (window-ID routed). Mouse-down physically on Icon (own item).
        let iconC = CGPoint(x: snap[.icon]!.frame.midX, y: snap[.icon]!.frame.midY)
        let b = await tryMove(.x, rightOf: .icon, variant: ice, startOverride: (.icon, iconC),
                              label: "5b offscreen X → rightOf Icon (ice, down on Icon)")
        log("  5b: \(b)")

        // 5c: on-screen → precise off-screen slot: X → rightOf Y (Y is off-screen, left of AH).
        if b {
            snap = snapshot()
            log("  Y frame \(fmt(snap[.y]!.frame)) (off-screen)")
            let c = await tryMove(.x, rightOf: .y, variant: ice, label: "5c onscreen X → rightOf offscreen Y (ice)")
            log("  5c: \(c)")
            // 5d: off-screen → different off-screen slot: X → leftOf H (both off-screen), down on Icon.
            snap = snapshot()
            let iconC2 = CGPoint(x: snap[.icon]!.frame.midX, y: snap[.icon]!.frame.midY)
            let d = await tryMove(.x, leftOf: .h, variant: ice, startOverride: (.icon, iconC2),
                                  label: "5d offscreen X → leftOf offscreen H (ice, down on Icon)")
            log("  5d: \(d)")
        }

        // 5e: plan (location-routed) variant, on-screen → off-screen: drop point is clamped to x=0.
        await switchState(.editing, pollMs: 500, quiet: true)
        if order(snapshot()) != targetOrder { await restoreOrder(using: plan) }
        await switchState(.expandedAll, pollMs: 500, quiet: true)
        _ = await tryMove(.x, rightOf: .icon, variant: plan, label: "5e setup: X → rightOf Icon (on-screen)")
        await switchState(.collapsed, pollMs: 700, quiet: true)
        let e1 = await tryMove(.x, rightOf: .y, variant: plan, label: "5e plan-variant X → rightOf offscreen Y (drop clamps to x=0)")
        log("  5e: precise off-screen target with location routing: \(e1); order=\(orderString(snapshot()))")

        // 5f: fallback — temporarily expandedAll → re-read frames → move → restore.
        await switchState(.editing, pollMs: 500, quiet: true)
        if order(snapshot()) != targetOrder { await restoreOrder(using: plan) }
        await switchState(.collapsed, pollMs: 700, quiet: true)
        await fallbackMove(.x, rightOf: .icon, variant: plan)
        await fallbackMove(.x, leftOf: .h, variant: plan)
        await switchState(.editing, pollMs: 500, quiet: true)
        if order(snapshot()) != targetOrder { await restoreOrder(using: plan) }
    }

    func fallbackMove(_ n: Name, rightOf: Name? = nil, leftOf: Name? = nil, variant v: DragVariant) async {
        let t = Date()
        let (lastChange, stable) = await switchState(.expandedAll, pollMs: 1000, quiet: true)
        log("  fallback: expandedAll settled (last change \(lastChange) ms, stable \(stable.map(String.init) ?? "n/a") ms)")
        var ok = await tryMove(n, rightOf: rightOf, leftOf: leftOf, variant: v, label: "fallback expandedAll")
        if !ok && leftOf == .h {
            await switchState(.editing, pollMs: 500, quiet: true)
            ok = await tryMove(n, rightOf: rightOf, leftOf: leftOf, variant: v, label: "fallback editing(H.len=8)")
        }
        await switchState(.collapsed, pollMs: 700, quiet: true)
        log("  fallback total \(ms(since: t)) ms, success=\(ok), order=\(orderString(snapshot()))")
    }

    // Steps 6 & 7 -------------------------------------------------------------------------------

    func step6and7() async {
        header("STEPS 6+7: click X (NSMenu) and Y (NSPopover) via AXPress and CGEvent; detect close")
        await switchState(.editing, pollMs: 400, quiet: true)
        if order(snapshot()) != targetOrder, let v = workingVariant { await restoreOrder(using: v) }
        for n in [Name.x, .y] {
            // X is in the hidden section (visible when expanded); Y is always-hidden (needs expandedAll).
            await switchState(n == .x ? .expanded : .expandedAll, pollMs: 700, quiet: true)
            printSnapshot(snapshot())
            for method in (env["SPIKE_CLICK_METHODS"]?.split(separator: ",").map(String.init) ?? ["AXPress", "CGEvent", "CGEvent+windowFields"]) {
                await clickTest(n, method: method)
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
        // AXPress on items that are pushed off-screen (collapsed): does the action fire, where does UI appear?
        await switchState(.collapsed, pollMs: 700, quiet: true)
        log("  --- AXPress while collapsed (X, Y off-screen) ---")
        await clickTest(.x, method: "AXPress")
        try? await Task.sleep(for: .milliseconds(700))
        await clickTest(.y, method: "AXPress")
        log("  (unrelated simultaneous menu: not constructed — skipped)")
    }

    func clickTest(_ n: Name, method: String) async {
        let snap = snapshot()
        guard let w = snap[n] else { return }
        let center = CGPoint(x: w.frame.midX, y: w.frame.midY)
        events.removeAll()
        let baseline = Set(windowList([.optionOnScreenOnly]).map(\.id))
        // Schedule the close 2 s from now *before* opening (menu tracking runs a nested run loop).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            MainActor.assumeIsolated {
                if n == .x { log("  → menu.cancelTracking()"); self.menu.cancelTracking() }
                else if self.popover.isShown { log("  → popover.performClose(nil)"); self.popover.performClose(nil) }
            }
        }
        let poller = Task { await pollNewWindows(baseline: baseline, durationMs: 3200) }
        let t0 = Date()
        var result = ""
        switch method {
        case "AXPress":
            // Run AXPress from a child process (cross-process, like Frost → other app). Don't block.
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            proc.arguments = ["--axpress", String(pid), String(Double(center.x))]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.terminationHandler = { _ in
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                log("  AXPress(\(n.short)) child finished at +\(ms(since: t0)) ms: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            do { try proc.run(); result = "AXPress child launched" } catch { result = "launch failed \(error)" }
        default:
            guard pointIsOnSpikeItem(center, expect: n) else { poller.cancel(); return }
            let id = ids[n]!
            let fields = method.contains("Fields")
            await Task.detached { postClick(at: center, windowID: id, withFields: fields) }.value
            result = "posted"
        }
        let seen = await poller.value
        log("  [\(n.short) via \(method)] \(result); delegate events: \(events)")
        if seen.isEmpty { log("    no new on-screen windows appeared") }
        for s in seen {
            let rel = s.win.frame.minX - w.frame.minX
            log("    new window \(s.win.desc) firstSeen=\(s.firstMs) ms lastSeen=\(s.lastMs) ms (gone by 3200 ms: \(s.lastMs < 3000)); x offset vs item: \(String(format: "%.1f", rel)); top vs menubar bottom: \(String(format: "%.1f", s.win.frame.minY - w.frame.maxY))")
        }
        // Make sure nothing is left open
        if popover.isShown { popover.performClose(nil) }
        menu.cancelTracking()
    }

    // Step 8 ------------------------------------------------------------------------------------

    func step8() async {
        header("STEP 8: crowded menu bar (expandedAll)")
        await switchState(.expandedAll, pollMs: 800, quiet: true)
        let main = mainBounds
        let notchL = NSScreen.screens.first?.auxiliaryTopLeftArea
        let notchR = NSScreen.screens.first?.auxiliaryTopRightArea
        let notch: CGRect? = (notchL != nil && notchR != nil) ? CGRect(x: notchL!.maxX, y: 0, width: notchR!.minX - notchL!.maxX, height: notchL!.height) : nil
        log("main display \(fmt(main)); notch (CG) \(notch.map(fmt) ?? "none")")
        let all = statusWindows().filter { abs($0.frame.minY - main.minY) < 1 }
        let own = Set(ids.values)
        var hidden: [Win] = []
        for w in all.sorted(by: { $0.frame.minX < $1.frame.minX }) {
            let c = CGPoint(x: w.frame.midX, y: w.frame.midY)
            let onMain = main.contains(c)
            let underNotch = notch.map { $0.intersects(w.frame) } ?? false
            let otherDisplay = displays().contains { $0.id != CGMainDisplayID() && $0.bounds.contains(c) }
            if otherDisplay { continue }
            let visible = onMain && !underNotch && w.onscreen && w.frame.width > 0
            if !visible { hidden.append(w) }
            log("  \(visible ? "VISIBLE" : "HIDDEN ") \(own.contains(w.id) ? "[spike]" : "       ") \(w.desc)\(underNotch ? " UNDER-NOTCH" : "")")
        }
        let others = displays().filter { $0.id != CGMainDisplayID() }.map(\.bounds)
        let onRow = all.filter { w in !others.contains { $0.contains(CGPoint(x: w.frame.midX, y: w.frame.midY)) } }
        log("items on main-display menu bar row: \(onRow.count); not visible in expandedAll: \(hidden.count)")
    }
}

// MARK: - Main

// Helper mode: `menubar-spike --axpress <pid> <midX>` performs AXPress from a separate process.
// (AX calls into one's own process are short-circuited in-process on the calling thread, so the
// spike must AXPress its own items from a child process to mimic Frost pressing another app's item.)
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--axpress",
   let pid = pid_t(CommandLine.arguments[2]), let midX = Double(CommandLine.arguments[3]) {
    print(axPress(pid: pid, midX: CGFloat(midX)))
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let spike = Spike()
    app.delegate = spike
    app.setActivationPolicy(.accessory)
    app.run()
}
