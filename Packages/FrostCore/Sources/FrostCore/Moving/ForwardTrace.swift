/// Milestones of one Frost Bar click forward (tile click → item moved out → click → menu), in milliseconds since the
/// click on the tile. Logged as one line per forward so the click-to-menu latency can be broken down from the log
/// alone (`FrostBarController.activate`).
public struct ForwardTrace: Sendable {
    public struct Mark: Sendable, Equatable {
        public let label: String
        public let at: Duration
    }

    public let start: ContinuousClock.Instant
    public private(set) var marks: [Mark] = []

    public init(start: ContinuousClock.Instant = .now) {
        self.start = start
    }

    public mutating func mark(_ label: String, at instant: ContinuousClock.Instant = .now) {
        marks.append(Mark(label: label, at: instant - start))
    }

    /// "label ms, label ms, ...", in the order the marks were made.
    public var description: String {
        marks.map { "\($0.label) \(Self.milliseconds($0.at))" }.joined(separator: ", ")
    }

    static func milliseconds(_ duration: Duration) -> Int {
        Int((duration / .milliseconds(1)).rounded())
    }
}
