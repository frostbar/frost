/// Decides whether the menu bar has settled after a section switch (a separator length change) — pure logic,
/// fed one polled snapshot at a time.
///
/// Rule: the snapshot must already differ from the pre-switch baseline (the change has taken effect) and be
/// identical for `requiredStablePolls` consecutive polls. There is no minimum wait: with the fast polling used by
/// live refresh (about every 16 ms), it finishes as soon as the change takes effect and the next poll confirms
/// nothing else changed.
public struct SettleDetector<Snapshot: Equatable> {
    public let baseline: Snapshot
    public let requiredStablePolls: Int
    private var previous: Snapshot?
    private var stablePolls = 0

    public init(baseline: Snapshot, requiredStablePolls: Int = 2) {
        self.baseline = baseline
        self.requiredStablePolls = max(1, requiredStablePolls)
    }

    /// Feeds one polled snapshot; returns whether things have settled.
    public mutating func observe(_ snapshot: Snapshot) -> Bool {
        defer { previous = snapshot }
        guard snapshot != baseline else {
            stablePolls = 0
            return false
        }
        stablePolls = snapshot == previous ? stablePolls + 1 : 1
        return stablePolls >= requiredStablePolls
    }
}
