#if DEBUG
import AppKit
import FrostCore
import QuartzCore

/// Debug-only frame timing probe for window interactions (e.g. switching settings tabs), enabled with
/// `FROST_TEST_FRAME_PROBE=1` (`make vm-run FROST_ENV="FROST_TEST_FRAME_PROBE=1"`).
///
/// `mark(_:in:)` starts a measurement window: a display link on the window ticks on the main run loop once per refresh,
/// so a gap between ticks is time the main thread could not produce a frame (a hitch). After `duration` it logs the
/// latency from the mark to the first tick, the longest gap, the number of hitches (gaps longer than 1.5 refresh
/// periods), the total hitch time (the part of each gap beyond one period) and where each hitch happened (`at=` lists
/// `<ms after the mark>+<gap ms>`), to `FrostLog.app` as `frame-probe <label> ...`.
@MainActor
final class FrameProbe: NSObject {
    static let isEnabled = ProcessInfo.processInfo.environment["FROST_TEST_FRAME_PROBE"] == "1"

    private static var current: FrameProbe?
    private static var isTriggerInstalled = false

    /// Lets a test tool start a measurement without interacting with the window (a baseline):
    /// post the distributed notification `dev.frost.Frost.frameProbe` with the label as its object.
    static func installTrigger(window: NSWindow) {
        guard isEnabled, !isTriggerInstalled else { return }
        isTriggerInstalled = true
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.frost.Frost.frameProbe"), object: nil,
                                                            queue: .main) { [weak window] note in
            let label = note.object as? String ?? "trigger"
            MainActor.assumeIsolated {
                if let window { mark(label, in: window) }
            }
        }
    }

    static func mark(_ label: String, in window: NSWindow, duration: Duration = .milliseconds(1200)) {
        guard isEnabled else { return }
        current?.finish()
        let probe = FrameProbe(label: label, duration: duration)
        current = probe
        probe.start(in: window)
    }

    private let label: String
    private let duration: Double
    private let start = CACurrentMediaTime()
    private var link: CADisplayLink?
    private var ticks: [CFTimeInterval] = []
    private var period: CFTimeInterval = 1.0 / 60

    private init(label: String, duration: Duration) {
        self.label = label
        let parts = duration.components
        self.duration = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private func start(in window: NSWindow) {
        let link = window.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if link.duration > 0 { period = link.duration }
        ticks.append(now)
        if now - start >= duration { finish() }
    }

    private func finish() {
        guard let link else { return }
        link.invalidate()
        self.link = nil
        if Self.current === self { Self.current = nil }

        let firstFrame = (ticks.first.map { $0 - start } ?? duration) * 1000
        var maxGap = 0.0, hitches = 0, hitchTime = 0.0
        var previous = start
        var hitchList: [String] = []
        for tick in ticks {
            let gap = tick - previous
            maxGap = max(maxGap, gap)
            if gap > period * 1.5 {
                hitchList.append(String(format: "%.0f+%.0f", (previous - start) * 1000, gap * 1000))
                hitches += 1
                hitchTime += gap - period
            }
            previous = tick
        }
        let summary = String(format: "frames=%d firstFrame=%.1fms maxGap=%.1fms hitches=%d hitchTime=%.1fms period=%.1fms",
                             ticks.count, firstFrame, maxGap * 1000, hitches, hitchTime * 1000, period * 1000)
        let at = hitchList.joined(separator: ",")
        FrostLog.app.notice("frame-probe \(self.label, privacy: .public) \(summary, privacy: .public) at=\(at, privacy: .public)")
    }
}
#endif
