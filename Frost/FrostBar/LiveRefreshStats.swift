import FrostCore
import Foundation

/// Frost Bar live refresh statistics: logs a one-line summary when the panel closes (average / max time per round,
/// pause reasons) and one line on each pause / resume. Per-round timings are logged only with
/// `FROST_LIVE_REFRESH_TRACE=1` (see `FrostBarController`).
struct LiveRefreshStats {
    /// Time breakdown of one round.
    struct Timing: CustomStringConvertible {
        /// Capture the menu bar and show the freeze frame (until it is actually on screen).
        var freezeFrame: Duration = .zero
        /// Expand temporarily and wait for the layout to settle.
        var expand: Duration = .zero
        /// Capture (strip capture + crop; per window when needed).
        var capture: Duration = .zero
        /// Collapse, wait to settle, then wait another `MenuBarFreezeFrame.settleDelay`.
        var collapse: Duration = .zero
        /// Time the freeze frame was on screen (shown to removed).
        var overlay: Duration = .zero
        var total: Duration = .zero
        /// Number of items captured per window (strip capture unavailable).
        var perWindow = 0

        var description: String {
            "freeze frame \(Self.ms(freezeFrame)), expand \(Self.ms(expand)), capture \(Self.ms(capture)), "
                + "collapse \(Self.ms(collapse)); overlay up \(Self.ms(overlay)), total \(Self.ms(total))"
                + (perWindow > 0 ? "; \(perWindow) captured per window" : "")
        }

        static func ms(_ duration: Duration) -> String {
            let (seconds, attoseconds) = duration.components
            return String(format: "%.0f ms", Double(seconds) * 1000 + Double(attoseconds) / 1e15)
        }
    }

    private(set) var cycles = 0
    private var sum = Timing()
    private var maxOverlay: Duration = .zero
    private var captured = 0
    private var requested = 0
    private var skips: [LiveRefreshPolicy.SkipReason: Int] = [:]
    private var pausedFor: LiveRefreshPolicy.SkipReason?
    private var abortedCycles = 0
    private var perWindowCycles = 0
    private var freezeFrameFailures = 0
    private let started = ContinuousClock.now

    mutating func record(_ timing: Timing, captured: Int, of requested: Int) {
        cycles += 1
        sum.freezeFrame += timing.freezeFrame
        sum.expand += timing.expand
        sum.capture += timing.capture
        sum.collapse += timing.collapse
        sum.overlay += timing.overlay
        sum.total += timing.total
        maxOverlay = max(maxOverlay, timing.overlay)
        if timing.perWindow > 0 { perWindowCycles += 1 }
        self.captured += captured
        self.requested += requested
    }

    /// This round was skipped; logs a line when the reason changes.
    mutating func skip(_ reason: LiveRefreshPolicy.SkipReason) {
        skips[reason, default: 0] += 1
        guard pausedFor != reason else { return }
        pausedFor = reason
        FrostLog.frostBar.notice("live refresh paused: \(reason.rawValue, privacy: .public)")
    }

    /// This round may run; logs a "resumed" line if refreshing was paused before.
    mutating func resume() {
        guard let reason = pausedFor else { return }
        pausedFor = nil
        FrostLog.frostBar.notice("live refresh resumed (was paused: \(reason.rawValue, privacy: .public))")
    }

    mutating func aborted() { abortedCycles += 1 }

    mutating func freezeFrameFailed() {
        freezeFrameFailures += 1
        if freezeFrameFailures == 1 { FrostLog.frostBar.error("freeze frame unavailable; not expanding the menu bar") }
    }

    /// Summary for when the panel closes; nil if nothing happened.
    func summary() -> String? {
        guard cycles > 0 || !skips.isEmpty || abortedCycles > 0 || freezeFrameFailures > 0 else { return nil }
        var parts = ["\(cycles) cycle(s) in \(Timing.ms(ContinuousClock.now - started))"]
        if cycles > 0 {
            let n = cycles
            parts.append("avg freeze frame \(Timing.ms(sum.freezeFrame / n)), expand \(Timing.ms(sum.expand / n)), "
                + "capture \(Timing.ms(sum.capture / n)), collapse \(Timing.ms(sum.collapse / n)), "
                + "overlay up \(Timing.ms(sum.overlay / n)) (max \(Timing.ms(maxOverlay))), "
                + "total \(Timing.ms(sum.total / n))")
            parts.append("captured \(captured) of \(requested) item image(s)")
            if perWindowCycles > 0 { parts.append("\(perWindowCycles) cycle(s) fell back to per-window captures") }
        }
        if !skips.isEmpty {
            let list = skips.sorted { $0.value > $1.value }.map { "\($0.key.rawValue)×\($0.value)" }
            parts.append("skipped " + list.joined(separator: ", "))
        }
        if abortedCycles > 0 { parts.append("\(abortedCycles) aborted") }
        if freezeFrameFailures > 0 { parts.append("\(freezeFrameFailures) freeze frame failure(s)") }
        return parts.joined(separator: "; ")
    }
}
