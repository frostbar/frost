/// Limits how often each key's value is written to disk: the first value for a key is written right away, later ones
/// at most once per `interval`; values arriving in between are kept (only the newest) until they are due or flushed.
///
/// Used for the item image disk cache: live refresh recaptures dynamic icons (a clock, a CPU meter) about once per
/// second while the Frost Bar is open, and writing a PNG + JSON pair for every change would be pointless disk I/O.
/// The disk cache only needs to be reasonably fresh for the next launch; the newest capture is flushed when the
/// panel closes and when Frost quits.
public struct DiskWriteThrottle<Key: Hashable, Value> {
    public let interval: Duration
    private var lastWrite: [Key: ContinuousClock.Instant] = [:]
    /// Values held back, newest per key.
    public private(set) var pending: [Key: Value] = [:]

    public init(interval: Duration) {
        self.interval = interval
    }

    /// A new value for `key`: returns it if it should be written now (and records the write), or nil if it was held
    /// back (replacing any older pending value for the key).
    public mutating func offer(_ value: Value, for key: Key, now: ContinuousClock.Instant) -> Value? {
        if let last = lastWrite[key], now - last < interval {
            pending[key] = value
            return nil
        }
        pending[key] = nil
        lastWrite[key] = now
        return value
    }

    /// Removes and returns the pending values whose key may be written again (`interval` elapsed since its last
    /// write), recording them as written.
    public mutating func takeDue(now: ContinuousClock.Instant) -> [(key: Key, value: Value)] {
        let due = pending.filter { key, _ in lastWrite[key].map { now - $0 >= interval } ?? true }
        for key in due.keys {
            pending[key] = nil
            lastWrite[key] = now
        }
        return due.map { (key: $0.key, value: $0.value) }
    }

    /// Removes and returns every pending value (panel closed, Frost quitting), recording them as written.
    public mutating func takeAll(now: ContinuousClock.Instant) -> [(key: Key, value: Value)] {
        let all = pending
        pending.removeAll()
        for key in all.keys { lastWrite[key] = now }
        return all.map { (key: $0.key, value: $0.value) }
    }
}

/// Runs a periodic chore (e.g. pruning the disk cache) at most once per `interval`, and the first time it is asked.
public struct PeriodicSchedule: Sendable {
    public let interval: Duration
    public private(set) var lastRun: ContinuousClock.Instant?

    public init(interval: Duration) {
        self.interval = interval
    }

    /// Whether the chore is due now; if so, records it as run.
    public mutating func runIfDue(now: ContinuousClock.Instant) -> Bool {
        if let lastRun, now - lastRun < interval { return false }
        lastRun = now
        return true
    }
}
