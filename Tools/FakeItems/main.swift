// FakeItems: a throw-away menu bar app for GUI-testing Frost inside the test VM.
// It creates several status items with distinct autosave names and different
// widths / behaviours (NSMenu, NSPopover, no-op). The item set is chosen by the
// bundle identifier, so the same source builds two apps with different owners:
//   dev.frost.FakeItems   9 items (menus, 2 popovers, 1 no-op, 1 ticking clock)
//   dev.frost.FakeItemsB  2 items (menus)
// FIClock is dynamic: its title is the number of seconds since launch ("0s", "1s", ...), updated every
// second, so its width changes at 10 s and 100 s. It exercises Frost Bar's live refresh of hidden items.
// FAKEITEMS_NET=1 (environment): FIClock shows a network-speed-like text instead ("4KB/s", "503KB/s", ...) that
// changes its width every second, like a network-speed menu bar item.
// FAKEITEMS_EXTRA=n (environment) adds n text items "Extra 0"... with menus.
// FAKEITEMS_POLITE=1 (environment) makes the popover items activate the app politely
// (NSApp.activate(), macOS 14+ cooperative activation) instead of forcing it with
// activate(ignoringOtherApps:). That is what many real menu bar apps do; without an
// activation hand-off from Frost the transient popover then ignores outside clicks.
// Every interaction is appended to /tmp/fakeitems.log so tests can verify that a
// click forwarded by Frost really reached the item.
// Build + deploy: scripts/vm/vm-fake-items.sh. Never run it on the host desktop.
import AppKit

enum Behaviour { case menu, popover, noop }

struct Spec {
    let autosave: String
    let title: String?
    let symbol: String?
    let behaviour: Behaviour
    /// The title counts seconds since launch ("12s"), updated every second.
    var ticking = false
}

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
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: spec.autosave)
            }
            if let title = spec.title { button.title = title }
            button.setAccessibilityLabel(spec.autosave)
            switch spec.behaviour {
            case .menu:
                let menu = NSMenu(title: spec.autosave)
                menu.delegate = self
                names[ObjectIdentifier(menu)] = spec.autosave
                for i in 1...3 {
                    let entry = NSMenuItem(title: "\(spec.autosave) option \(i)", action: #selector(pick(_:)), keyEquivalent: "")
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
            }
            items.append(item)
            if spec.ticking { startTicking(button) }
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
MainActor.assumeIsolated {
    controller.install((Bundle.main.bundleIdentifier == "dev.frost.FakeItemsB" ? specsB : specsA) + extraSpecs)
}
app.run()
