/// Counts the attempts of one move (`ItemMover.move`) and decides whether another may follow.
///
/// A ⌘-drag the user's own mouse cut short (a button pressed while the synthetic button was down: the mouse-up is posted
/// at once and the item may land elsewhere or not move) or that wasn't posted at all (a button pressed at the last
/// moment) says nothing about whether the move works: it gets another attempt without using up `limit`, up to
/// `interruptionLimit` such attempts. Otherwise a click at the wrong moment used up the retries of a Frost Bar move back,
/// which then fell back to the section's edge instead of the item's slot. While quitting, every attempt counts against
/// `shutdownLimit` so quitting stays responsive.
public struct MoveAttempts: Sendable {
    public enum Outcome: Sendable {
        /// The ⌘-drag ran but the item isn't where it should be.
        case failed
        /// The user pressed a mouse button during the ⌘-drag.
        case interrupted
        /// A mouse button was down right before the mouse-down: nothing was posted.
        case notPosted
    }

    public let limit: Int
    public let interruptionLimit: Int
    public let shutdownLimit: Int
    public private(set) var failed = 0
    public private(set) var interrupted = 0

    public init(limit: Int, interruptionLimit: Int, shutdownLimit: Int = 1) {
        self.limit = max(1, limit)
        self.interruptionLimit = max(0, interruptionLimit)
        self.shutdownLimit = max(1, shutdownLimit)
    }

    /// Attempts made so far.
    public var count: Int { failed + interrupted }

    public mutating func record(_ outcome: Outcome) {
        switch outcome {
        case .failed: failed += 1
        case .interrupted, .notPosted: interrupted += 1
        }
    }

    /// Whether another attempt may be made.
    public func mayAttempt(isShuttingDown: Bool) -> Bool {
        if isShuttingDown { return count < min(limit, shutdownLimit) }
        return failed < limit && interrupted <= interruptionLimit
    }
}
