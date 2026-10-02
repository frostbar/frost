import CoreGraphics

/// Decides whether a scan needs to re-read the AX of every process in the background
/// (`AXExtrasReader.readAll`, about 300 ms, of which a single hung process uses up the full 0.25 s AX timeout).
///
/// Rule: if every window on the scanned menu bar either has cached ownership or is "known unresolvable" and was
/// last tried less than `retryInterval` ago, use the cache; otherwise (a new window appeared, or an unresolved
/// window is due for a retry) do a full read.
public enum OwnershipRefreshPolicy {
    public static let retryInterval: Duration = .seconds(5)
    /// How many follow-up reads the scanner schedules by itself when windows are still unresolved after a read.
    public static let maxScheduledRetries = 3

    /// Whether to schedule another full read on its own (`retryInterval` later) after a read that left `unresolved`
    /// windows. Rescans retry unresolved windows anyway, but only when something rescans: right after launch, while
    /// Frost's separators are still pushing items out, the read can't match the moving windows, and nothing may rescan
    /// until the user opens the Frost Bar or the layout editor, which would then show placeholders instead of the
    /// disk-cached images (they are keyed by owner). Bounded so windows that never resolve don't cost a read forever.
    public static func shouldScheduleRetry(unresolved: Int, retriesSoFar: Int,
                                           maxRetries: Int = maxScheduledRetries) -> Bool {
        unresolved > 0 && retriesSoFar < maxRetries
    }

    /// - Parameters:
    ///   - windowIDs: The windows found by this scan.
    ///   - cached: Windows with cached ownership.
    ///   - unresolvedSince: Windows still unresolved after the last full read → the time of that read.
    public static func needsFullRead(windowIDs: [CGWindowID], cached: Set<CGWindowID>,
                                     unresolvedSince: [CGWindowID: ContinuousClock.Instant],
                                     now: ContinuousClock.Instant,
                                     retryInterval: Duration = retryInterval) -> Bool {
        windowIDs.contains { id in
            if cached.contains(id) { return false }
            guard let since = unresolvedSince[id] else { return true }
            return now - since >= retryInterval
        }
    }
}
