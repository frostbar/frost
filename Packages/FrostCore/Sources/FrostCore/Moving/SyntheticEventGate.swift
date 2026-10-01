import Synchronization

/// Counts synthetic event sequences being posted right now (a ⌘-drag's mouse-down → mouse-up → cursor restore, a
/// forwarded click). Posting runs on background threads; quitting checks `isPosting` so the process never exits
/// between a mouse-down and its mouse-up, or before the cursor is restored.
public enum SyntheticEventGate {
    private static let inFlight = Mutex(0)

    /// Whether a sequence is being posted right now (any thread).
    public static var isPosting: Bool { inFlight.withLock { $0 > 0 } }

    /// Runs `body` (which posts one complete event sequence) while counted as in flight.
    public static func posting<T>(_ body: () throws -> T) rethrows -> T {
        inFlight.withLock { $0 += 1 }
        defer { inFlight.withLock { $0 -= 1 } }
        return try body()
    }
}
