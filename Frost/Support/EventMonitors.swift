import AppKit

/// Global + local `NSEvent` monitors for the same events: global monitors see events sent to other apps, local ones
/// events sent to Frost's own windows (which global monitors never receive). Local events are always passed on
/// unchanged. Handlers run on the main thread.
@MainActor
struct EventMonitors {
    private var tokens: [Any] = []

    var isEmpty: Bool { tokens.isEmpty }

    /// Adds a global monitor calling `global` and a local one calling `local` (the same handler when nil).
    mutating func add(matching mask: NSEvent.EventTypeMask, global: @escaping @MainActor (NSEvent) -> Void,
                      local: (@MainActor (NSEvent) -> Void)? = nil) {
        let local = local ?? global
        if let token = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { global(event) }
        }) {
            tokens.append(token)
        }
        if let token = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { local(event) }
            return event
        }) {
            tokens.append(token)
        }
    }

    mutating func removeAll() {
        for token in tokens { NSEvent.removeMonitor(token) }
        tokens.removeAll()
    }
}

extension NSEvent {
    /// The event's location in AppKit screen coordinates. A global monitor's events have no window, so their
    /// `locationInWindow` already is in screen coordinates.
    @MainActor var screenLocation: CGPoint {
        window.map { $0.convertPoint(toScreen: locationInWindow) } ?? locationInWindow
    }
}
