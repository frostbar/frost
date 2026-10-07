// FakeItems: a throw-away menu bar app for GUI-testing Frost inside the test VM.
// It creates several status items with distinct autosave names and different
// widths / behaviours (NSMenu, NSPopover, no-op). The item set is chosen by the
// bundle identifier, so the same source builds two apps with different owners:
//   dev.frost.FakeItems   10 items (menus, 2 popovers, 1 no-op, 1 ticking clock, 1 with separate left / right menus)
//   dev.frost.FakeItemsB  2 items (menus)
// FIClock is dynamic: its title is the number of seconds since launch ("0s", "1s", ...), updated every
// second, so its width changes at 10 s and 100 s. It exercises Frost Bar's live refresh of hidden items.
// FAKEITEMS_NET=1 (environment): FIClock shows a network-speed-like text instead ("4KB/s", "503KB/s", ...) that
// changes its width every second, like a network-speed menu bar item.
// FAKEITEMS_EXTRA=n (environment) adds n text items "Extra 0"... with menus.
// FAKEITEMS_LIVE=1 (environment) adds three items after the others, for identity stability tests: FILiveHelp (no AX
// description; its tooltip, i.e. AX help, shows fan-speed-like readings that change every second), FILiveDesc (its AX
// description is a temperature-like reading that changes every second) and FIBlink (no AX description or help; hidden
// for 4 s every 20 s with `isVisible`, like a chat app's icon that blinks for unread messages).
// FAKEITEMS_POLITE=1 (environment) makes the popover items activate the app politely
// (NSApp.activate(), macOS 14+ cooperative activation) instead of forcing it with
// activate(ignoringOtherApps:). That is what many real menu bar apps do; without an
// activation hand-off from Frost the transient popover then ignores outside clicks.
// FIDual (gear) shows a "primary" menu on a left click (with an extra entry when the click carries Option) and a
// different "secondary" menu on a right click / Control-click, like many real status items.
// Every interaction is appended to /tmp/fakeitems.log so tests can verify that a
// click forwarded by Frost really reached the item.
// Build + deploy: scripts/vm/vm-fake-items.sh. Never run it on the host desktop.
import AppKit

enum Behaviour { case menu, popover, noop, dual }

struct Spec {
    let autosave: String
    let title: String?
    let symbol: String?
    let behaviour: Behaviour
    /// The title counts seconds since launch ("12s"), updated every second.
    var ticking = false
    /// FAKEITEMS_LIVE=1 items (see the header).
    var live: Live?
    /// Menu entries instead of "<autosave> option N" (FAKEITEMS_DEMO=1).
    var entries: [String]?
}

enum Live { case help, description, blink }

let liveSpecs: [Spec] = [
    Spec(autosave: "FILiveHelp", title: nil, symbol: "fanblades.fill", behaviour: .menu, live: .help),
    Spec(autosave: "FILiveDesc", title: nil, symbol: "thermometer.medium", behaviour: .menu, live: .description),
    Spec(autosave: "FIBlink", title: nil, symbol: "message.fill", behaviour: .menu, live: .blink),
]

let specsA: [Spec] = [
    Spec(autosave: "FIMenuA", title: "A", symbol: nil, behaviour: .menu),
    Spec(autosave: "FIWide", title: "Wide Text Item", symbol: nil, behaviour: .menu),
    Spec(autosave: "FIStar", title: nil, symbol: "star.fill", behaviour: .menu),
    Spec(autosave: "FIPopover", title: nil, symbol: "cloud.sun.fill", behaviour: .popover),
    Spec(autosave: "FINoop", title: nil, symbol: "circle.dashed", behaviour: .noop),
    Spec(autosave: "FIPercent", title: "42%", symbol: nil, behaviour: .menu),
    Spec(autosave: "FIBolt", title: nil, symbol: "bolt.fill", behaviour: .menu),
    Spec(autosave: "FIBeta", title: "Beta ◆", symbol: nil, behaviour: .popover),
    Spec(autosave: "FIClock", title: "0s", symbol: nil, behaviour: .menu, ticking: true),
    Spec(autosave: "FIDual", title: nil, symbol: "gearshape.fill", behaviour: .dual),
]

/// FAKEITEMS_DEMO=1: a tidy set of items with neutral names and realistic menus, for README recordings.
let demoSpecs: [Spec] = [
    Spec(autosave: "FIDemoPercent", title: "42%", symbol: nil, behaviour: .menu,
         entries: ["Battery: 42%", "Power Source: Battery", "Low Power Mode", "Energy Settings…"]),
    Spec(autosave: "FIDemoSun", title: nil, symbol: "cloud.sun.fill", behaviour: .menu,
         entries: ["Sunny, 22°", "Tomorrow: 24°", "Refresh"]),
    Spec(autosave: "FIDemoBolt", title: nil, symbol: "bolt.fill", behaviour: .menu,
         entries: ["Charging: Off", "Optimized Charging", "Show Battery Health"]),
    Spec(autosave: "FIDemoLeaf", title: nil, symbol: "leaf.fill", behaviour: .menu,
         entries: ["Focus: Off", "Do Not Disturb", "Reading", "Work"]),
    Spec(autosave: "FIDemoStar", title: nil, symbol: "star.fill", behaviour: .menu,
         entries: ["Favorites", "Recent Items", "Edit Favorites…"]),
    Spec(autosave: "FIDemoTimer", title: nil, symbol: "timer", behaviour: .menu,
         entries: ["Start Timer", "5 Minutes", "25 Minutes", "1 Hour"]),
    Spec(autosave: "FIDemoGear", title: nil, symbol: "gearshape.fill", behaviour: .menu,
         entries: ["Preferences…", "Check for Updates", "Quit"]),
]

let specsB: [Spec] = [
    Spec(autosave: "FBLeaf", title: nil, symbol: "leaf.fill", behaviour: .menu),
    Spec(autosave: "FBTwo", title: "B2", symbol: nil, behaviour: .menu),
]

func log(_ message: String) {
    let line = "\(Date().timeIntervalSince1970) \(Bundle.main.bundleIdentifier ?? "?") \(message)\n"
    let url = URL(fileURLWithPath: "/tmp/fakeitems.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    } else {
        try? line.data(using: .utf8)!.write(to: url)
    }
}

/// FAKEITEMS_NET=1: FIClock's width changes every second (see the header).
let netStyle = ProcessInfo.processInfo.environment["FAKEITEMS_NET"] == "1"
let netTitles = ["4KB/s", "503KB/s", "15KB/s", "1.2MB/s", "0KB/s", "88KB/s"]

/// FAKEITEMS_POLITE=1: popovers use cooperative activation (see the header).
let politeActivation = ProcessInfo.processInfo.environment["FAKEITEMS_POLITE"] == "1"

@MainActor
final class Controller: NSObject, NSMenuDelegate, NSPopoverDelegate {
    var items: [NSStatusItem] = []
    var popovers: [ObjectIdentifier: (NSPopover, String)] = [:]
    var names: [ObjectIdentifier: String] = [:]

    func install(_ specs: [Spec]) {
        for spec in specs {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = spec.autosave
            guard let button = item.button else { continue }
            if let symbol = spec.symbol {
                button.image = NSImage(systemSymbolName: symbol,
                                       accessibilityDescription: spec.live == nil ? spec.autosave : nil)
            }
            if let title = spec.title { button.title = title }
            if spec.live == nil { button.setAccessibilityLabel(spec.autosave) }
            switch spec.behaviour {
            case .menu:
                let menu = NSMenu(title: spec.autosave)
                menu.delegate = self
                names[ObjectIdentifier(menu)] = spec.autosave
                let titles = spec.entries ?? (1...3).map { "\(spec.autosave) option \($0)" }
                for title in titles {
                    let entry = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: "")
                    entry.target = self
                    menu.addItem(entry)
                }
                item.menu = menu
            case .popover:
                let popover = NSPopover()
                popover.behavior = .transient
                popover.delegate = self
                let vc = NSViewController()
                let label = NSTextField(labelWithString: "\(spec.autosave) popover")
                label.font = .systemFont(ofSize: 15, weight: .semibold)
                let box = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 90))
                label.frame = NSRect(x: 20, y: 35, width: 180, height: 22)
                box.addSubview(label)
                vc.view = box
                popover.contentViewController = vc
                popovers[ObjectIdentifier(button)] = (popover, spec.autosave)
                names[ObjectIdentifier(popover)] = spec.autosave
                button.target = self
                button.action = #selector(togglePopover(_:))
            case .noop:
                button.target = self
                button.action = #selector(noop(_:))
            case .dual:
                dualItems[ObjectIdentifier(button)] = item
                button.target = self
                button.action = #selector(dualClick(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            items.append(item)
            if spec.ticking { startTicking(button) }
            if let live = spec.live { startLive(live, item: item) }
        }
        log("launched with \(specs.count) items activation=\(politeActivation ? "polite" : "forced")")
        // Log every activation change so tests can see whether a polite activate() was granted.
        for (name, label) in [(NSApplication.didBecomeActiveNotification, "app became active"),
                              (NSApplication.didResignActiveNotification, "app resigned active")] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in log(label) }
        }
    }

    var ticker: Timer?
    let launched = Date()

    func startTicking(_ button: NSStatusBarButton) {
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self, weak button] _ in
            MainActor.assumeIsolated {
                guard let self, let button else { return }
                let seconds = Int(Date().timeIntervalSince(self.launched))
                button.title = netStyle ? netTitles[seconds % netTitles.count] : "\(seconds)s"
            }
        }
    }

    var liveItems: [(Live, NSStatusItem)] = []
    var liveTimer: Timer?
    var liveTick = 0

    /// FAKEITEMS_LIVE=1 (see the header).
    func startLive(_ live: Live, item: NSStatusItem) {
        liveItems.append((live, item))
        update(live, item)
        guard liveTimer == nil else { return }
        liveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.liveTick += 1
                for (live, item) in self.liveItems { self.update(live, item) }
            }
        }
    }

    func update(_ live: Live, _ item: NSStatusItem) {
        let tick = liveTick
        switch live {
        case .help:
            item.button?.toolTip = "Left side - \(4990 + tick * 7 % 50) RPM\nRight side - \(5012 - tick * 3 % 40) RPM"
        case .description:
            item.button?.setAccessibilityLabel("CPU \(40 + tick % 30)°C")
        case .blink:
            let visible = tick % 20 < 16
            if item.isVisible != visible {
                item.isVisible = visible
                log("FIBlink \(visible ? "shown" : "hidden")")
            }
        }
    }

    var dualItems: [ObjectIdentifier: NSStatusItem] = [:]

    /// FIDual: left click → primary menu (an extra entry with Option), right / Control click → secondary menu.
    @objc func dualClick(_ sender: NSStatusBarButton) {
        guard let item = dualItems[ObjectIdentifier(sender)] else { return }
        // AXPress runs the action without a mouse event (the current event may be nil or unrelated): a left click.
        let event = NSApp.currentEvent
        let isMouse = [.leftMouseUp, .rightMouseUp].contains(event?.type)
        let flags = isMouse ? event?.modifierFlags ?? [] : []
        let secondary = event?.type == .rightMouseUp || (isMouse && flags.contains(.control))
        let option = flags.contains(.option)
        log("dual click \(secondary ? "right" : "left") option=\(option)")
        let name = secondary ? "FIDualSecondary" : "FIDualPrimary"
        let menu = NSMenu(title: name)
        menu.delegate = self
        names[ObjectIdentifier(menu)] = name
        var titles = (1...3).map { "\(name) option \($0)" }
        if !secondary, option { titles.append("FIDualPrimary hidden option") }
        for title in titles {
            let entry = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        // The usual pattern: attach the menu for this click only, then detach it so the next click reaches the action.
        item.menu = menu
        sender.performClick(nil)
        item.menu = nil
    }

    @objc func pick(_ sender: NSMenuItem) { log("picked \(sender.title)") }

    @objc func noop(_ sender: NSStatusBarButton) { log("noop clicked \(sender.accessibilityLabel() ?? "")") }

    @objc func togglePopover(_ sender: NSStatusBarButton) {
        guard let (popover, name) = popovers[ObjectIdentifier(sender)] else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        log("popover click \(name) activation=\(politeActivation ? "polite" : "forced") buttonWindow=\(sender.window.map { NSStringFromRect($0.frame) } ?? "?")")
        if politeActivation {
            // Cooperative activation: granted only if the active app yielded to us (Frost's hand-off) or the
            // system treats the click as user intent for this app. Refused → the transient popover never sees
            // the app resign active and ignores outside clicks.
            NSApp.activate()
        } else {
            // Forced: always works, so the transient popover closes on outside clicks.
            NSApp.activate(ignoringOtherApps: true)
        }
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        // Activation is asynchronous: report the result a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            log("popover \(name) app active=\(NSApp.isActive)")
        }
    }

    func menuWillOpen(_ menu: NSMenu) { log("menu open \(names[ObjectIdentifier(menu)] ?? "?")") }
    func menuDidClose(_ menu: NSMenu) { log("menu close \(names[ObjectIdentifier(menu)] ?? "?")") }
    func popoverDidShow(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover else { return }
        log("popover shown \(names[ObjectIdentifier(popover)] ?? "?") window=\(popover.contentViewController?.view.window.map { NSStringFromRect($0.frame) } ?? "?")")
    }
    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover else { return }
        log("popover closed \(names[ObjectIdentifier(popover)] ?? "?")")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
// FAKEITEMS_EXTRA=n adds n more text items with menus (for Frost Bar width / scrolling tests).
let extra = Int(ProcessInfo.processInfo.environment["FAKEITEMS_EXTRA"] ?? "") ?? 0
let extraSpecs = (0..<extra).map { Spec(autosave: "FIExtra\($0)", title: "Extra \($0)", symbol: nil, behaviour: .menu) }
    + (ProcessInfo.processInfo.environment["FAKEITEMS_LIVE"] == "1" ? liveSpecs : [])
MainActor.assumeIsolated {
    if Bundle.main.bundleIdentifier == "dev.frost.FakeItemsDemo" {
        controller.install(demoSpecs)
    } else {
        controller.install((Bundle.main.bundleIdentifier == "dev.frost.FakeItemsB" ? specsB : specsA) + extraSpecs)
    }
}
app.run()
