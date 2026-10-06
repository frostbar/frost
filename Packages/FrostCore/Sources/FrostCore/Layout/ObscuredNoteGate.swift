import Foundation

/// Decides when the layout editor's "icons are off-screen" note is shown, so a count that flips for a moment never
/// makes the footer flicker (an app whose icon blinks for unread messages is re-added off screen every few seconds).
///
/// The note appears only after the count has been above zero for `showDelay` without a break, and goes away only
/// after it has been zero for `hideDelay`. While it is shown it follows the latest non-zero count.
public struct ObscuredNoteGate: Sendable {
    public var showDelay: TimeInterval
    public var hideDelay: TimeInterval
    /// The count the note shows; 0 while it is hidden.
    public private(set) var count = 0
    /// Since when the raw count has been non-zero (hidden) / zero (shown) without a break.
    private var changeStart: TimeInterval?

    public init(showDelay: TimeInterval = 5, hideDelay: TimeInterval = 10) {
        self.showDelay = showDelay
        self.hideDelay = hideDelay
    }

    /// Feeds the current raw count at `now` (seconds on any monotonic clock) and returns the count to show.
    @discardableResult
    public mutating func update(rawCount: Int, now: TimeInterval) -> Int {
        if count == 0 {
            guard rawCount > 0 else {
                changeStart = nil
                return 0
            }
            let start = changeStart ?? now
            changeStart = start
            if now - start >= showDelay {
                count = rawCount
                changeStart = nil
            }
        } else if rawCount > 0 {
            count = rawCount
            changeStart = nil
        } else {
            let start = changeStart ?? now
            changeStart = start
            if now - start >= hideDelay {
                count = 0
                changeStart = nil
            }
        }
        return count
    }

    /// Hides the note at once (a new editing session starts from a clean state).
    public mutating func reset() {
        count = 0
        changeStart = nil
    }
}
