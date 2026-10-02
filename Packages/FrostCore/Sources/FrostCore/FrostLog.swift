import os

/// Frost's unified logging (`os.Logger`, subsystem `dev.frost.Frost`).
///
/// Not `NSLog`: when Frost is launched by launchd (login item, Finder, `open`), stderr is `/dev/null`, and `NSLog`
/// output can't be found in the unified log on real hardware. To view:
/// `log show --last 10m --info --predicate 'subsystem == "dev.frost.Frost"'` (or `log stream`).
///
/// Privacy: diagnostic values such as window IDs, timings, displays, bundle IDs and errors use `.public`; values that
/// may contain user content (menu bar item titles / AX descriptions, and cache file names derived from them) use
/// `.private`. Levels: ordinary events `.notice` (persisted by default), failures `.error`, per-cycle details that
/// are only emitted when a trace switch is on `.info`.
public enum FrostLog {
    public static let subsystem = "dev.frost.Frost"

    /// Launch, quit.
    public static let app = Logger(subsystem: subsystem, category: "app")
    /// Section state, Frost icon clicks, active menu bar moving to another display.
    public static let sections = Logger(subsystem: subsystem, category: "sections")
    /// Menu bar scanning, multi-display resolution.
    public static let scanner = Logger(subsystem: subsystem, category: "scanner")
    /// ⌘-drag moves.
    public static let mover = Logger(subsystem: subsystem, category: "mover")
    /// Icon capture and the disk cache.
    public static let capture = Logger(subsystem: subsystem, category: "capture")
    /// Frost Bar panel, live refresh, click forwarding and moving back.
    public static let frostBar = Logger(subsystem: subsystem, category: "frostbar")
    /// Freeze frame.
    public static let freezeFrame = Logger(subsystem: subsystem, category: "freezeframe")
    /// Activation hand-off for click forwarding and the "click outside" fallback.
    public static let activation = Logger(subsystem: subsystem, category: "activation")
    /// Layout editor.
    public static let layout = Logger(subsystem: subsystem, category: "layout")
    /// New item placement and keeping icons in their sections.
    public static let newItems = Logger(subsystem: subsystem, category: "newitems")
}
