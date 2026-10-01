import CoreGraphics

/// A move destination, referencing the target menu bar item by window ID.
public enum MoveDestination: Hashable, Sendable {
    case leftOf(CGWindowID)
    case rightOf(CGWindowID)

    public var targetWindowID: CGWindowID {
        switch self {
        case .leftOf(let id), .rightOf(let id): id
        }
    }
}
