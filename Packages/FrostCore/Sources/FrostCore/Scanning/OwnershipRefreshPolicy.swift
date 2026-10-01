import CoreGraphics

/// Decides whether a scan needs to re-read the AX of every process in the background
/// (`AXExtrasReader.readAll`, about 300 ms, of which a single hung process uses up the full 0.25 s AX timeout).
///
/// Rule: if every window on the scanned menu bar either has cached ownership or is "known unresolvable" and was
/// last tried less than `retryInterval` ago, use the cache; otherwise (a new window appeared, or an unresolved
/// window is due for a retry) do a full read.
public enum OwnershipRefreshPolicy {
    public static let retryInterval: Duration = .seconds(5)

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
