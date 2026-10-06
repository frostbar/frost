import Foundation

/// Decides when an item moved out for a forwarded click goes back to its slot ("linger").
///
/// Moving it back the moment its presentation closes breaks a common follow-up: the user sees the icon in the menu bar
/// and clicks it again (often a right click for its other menu). That click first closes the open menu, Frost sees the
/// close and moves the icon away, and the click lands on nothing. So after the presentation closes the item stays out
/// only while the user is still interacting with it. It must not linger beyond that: while it sits right of the Frost
/// icon, the icon itself sits one item further left than where the user expects it, and a click on its usual spot hits
/// the item instead.
///
/// - The pointer is over the item (`pointerRegion`: its frame and a small margin; elsewhere on the menu bar doesn't
///   count): keep it (up to `idleCap` without a click).
/// - The user clicks the item (left or right, seen by a mouse-down monitor on its frame): wait up to `openTimeout` for a
///   new presentation and, if one opens, until it closes (a menu without limit, like the forwarded click; anything else
///   up to `presentationCap`), then start over.
/// - Otherwise move it back once the pointer has been away from the item for `leaveDelay`.
/// - Never while a mouse button is held (the move back is a ⌘-drag).
///
/// Interruptions (the Frost Bar reopens, Frost quits, the user is away, the layout editor opens) are the caller's: it
/// stops consulting this and moves the item back at once. A pure state machine: the caller polls with samples.
public struct ForwardLinger: Sendable {
    public struct Timing: Equatable, Sendable {
        /// How long the pointer must stay away from the item before it goes back.
        public var leaveDelay: Duration
        /// How long without a click (or an open presentation) the item stays out while the pointer rests on it.
        public var idleCap: Duration
        /// How long after a click on the item to wait for its presentation to appear.
        public var openTimeout: Duration
        /// How long a non-menu presentation opened from the menu bar may hold the item out.
        public var presentationCap: Duration

        public init(leaveDelay: Duration, idleCap: Duration, openTimeout: Duration, presentationCap: Duration) {
            self.leaveDelay = leaveDelay
            self.idleCap = idleCap
            self.openTimeout = openTimeout
            self.presentationCap = presentationCap
        }

        public static let standard = Timing(leaveDelay: .milliseconds(750), idleCap: .seconds(5), openTimeout: .seconds(1),
                                            presentationCap: .seconds(60))
    }

    public struct Sample: Equatable, Sendable {
        public var time: ContinuousClock.Instant
        /// The pointer is over the item (`ForwardLinger.pointerRegion(of:)`).
        public var isPointerOverItem: Bool
        /// Any mouse button is held (HID state, `UserMouseButtons`).
        public var isMouseButtonHeld: Bool
        /// The user pressed a mouse button on the item since the previous sample.
        public var clickedItem: Bool
        /// A presentation of the item's app (or a menu) newer than the linger baseline is on screen.
        public var isPresentationOpen: Bool
        /// That presentation includes a menu (layer 101): no time limit, a menu always closes on an outside click.
        public var isMenuOpen: Bool

        public init(time: ContinuousClock.Instant, isPointerOverItem: Bool, isMouseButtonHeld: Bool,
                    clickedItem: Bool = false, isPresentationOpen: Bool = false, isMenuOpen: Bool = false) {
            self.time = time
            self.isPointerOverItem = isPointerOverItem
            self.isMouseButtonHeld = isMouseButtonHeld
            self.clickedItem = clickedItem
            self.isPresentationOpen = isPresentationOpen
            self.isMenuOpen = isMenuOpen
        }
    }

    public enum Decision: Equatable, Sendable {
        case keep
        case restore(Reason)
    }

    public enum Reason: String, Equatable, Sendable {
        /// The pointer left the item `leaveDelay` ago.
        case pointerLeft = "pointer left"
        /// `idleCap` without a click while the pointer rested on the item.
        case idle = "idle"
        /// A non-menu presentation stayed open for `presentationCap`.
        case presentationCap = "presentation cap"
    }

    enum Phase: Equatable, Sendable {
        /// Nothing of the item's is open.
        case idle
        /// The user clicked the item; waiting for its presentation to appear (since).
        case awaitingPresentation(since: ContinuousClock.Instant)
        /// A presentation opened from the menu bar is on screen (since).
        case presenting(since: ContinuousClock.Instant)
    }

    /// Extra reach around the item's frame that still counts as being on it (points).
    public static let pointerMargin: CGFloat = 6

    /// Where the pointer counts as being on the item (CG coordinates): its frame with a small horizontal margin.
    public static func pointerRegion(of itemFrame: CGRect) -> CGRect {
        itemFrame.insetBy(dx: -pointerMargin, dy: 0)
    }

    public let timing: Timing
    private(set) var phase: Phase = .idle
    /// Last click on the item, presentation close, or the start.
    private var lastInteraction: ContinuousClock.Instant
    /// When the pointer was last seen over the item (or the start).
    private var pointerLastOver: ContinuousClock.Instant

    /// `start`: when the forwarded click's presentation closed.
    public init(start: ContinuousClock.Instant, timing: Timing = .standard) {
        self.timing = timing
        lastInteraction = start
        pointerLastOver = start
    }

    /// Whether the caller should refresh its window baseline now (nothing of the item's is open or expected, so new
    /// windows from now on are unrelated until the next click).
    public var acceptsNewBaseline: Bool { phase == .idle }

    public mutating func update(_ sample: Sample) -> Decision {
        let now = sample.time
        if sample.isPointerOverItem { pointerLastOver = now }
        if sample.clickedItem {
            lastInteraction = now
            if case .presenting = phase {
                // Clicking the item while its presentation is open usually closes it; the close shows up as usual.
            } else {
                phase = .awaitingPresentation(since: now)
            }
        }
        switch phase {
        case .idle:
            break
        case .awaitingPresentation(let since):
            if sample.isPresentationOpen {
                phase = .presenting(since: now)
            } else if now - since >= timing.openTimeout {
                phase = .idle
            }
        case .presenting(let since):
            if !sample.isPresentationOpen {
                phase = .idle
                lastInteraction = now
                pointerLastOver = max(pointerLastOver, now)
            } else if !sample.isMenuOpen, now - since >= timing.presentationCap, !sample.isMouseButtonHeld {
                return .restore(.presentationCap)
            }
        }
        if sample.isMouseButtonHeld { return .keep }
        switch phase {
        case .awaitingPresentation, .presenting:
            return .keep
        case .idle:
            if sample.isPointerOverItem {
                return now - lastInteraction >= timing.idleCap ? .restore(.idle) : .keep
            }
            return now - pointerLastOver >= timing.leaveDelay ? .restore(.pointerLeft) : .keep
        }
    }
}
