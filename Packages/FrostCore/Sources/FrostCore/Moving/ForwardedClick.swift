import CoreGraphics

/// Which click the Frost Bar forwards to a hidden item, chosen from the click on its tile.
///
/// - Plain left click: a plain left click (AXPress first, see `ItemClicker.click`).
/// - Right click, or Control + left click: a right click (HID `rightMouseDown` / `rightMouseUp`). Many status items
///   show a different (secondary) menu on a right click, chosen by the current event's type; AXPress / AXShowMenu
///   deliver no mouse event, so only a real right click reliably reaches that menu.
/// - Option + left click: a left click with the Option modifier (HID event; AXPress carries no modifiers). Some apps
///   show extra entries in their menu.
public enum ForwardedClick: Equatable, Sendable {
    case primary
    case secondary
    case primaryWithOption

    public enum Button: Equatable, Sendable { case left, right, other }

    /// Maps the click on a tile to the click to forward; nil for buttons that don't forward (e.g. the middle button).
    /// Control wins over Option (Control + left click is the classic right click).
    public static func kind(button: Button, control: Bool, option: Bool) -> ForwardedClick? {
        switch button {
        case .right: .secondary
        case .left where control: .secondary
        case .left where option: .primaryWithOption
        case .left: .primary
        case .other: nil
        }
    }

    /// Whether the click must be a HID event (AXPress can only do a plain primary click).
    public var requiresEvent: Bool { self != .primary }

    /// The mouse button of the forwarded events.
    public var mouseButton: CGMouseButton { self == .secondary ? .right : .left }

    /// The down / up event types of the forwarded click.
    public var eventTypes: (down: CGEventType, up: CGEventType) {
        self == .secondary ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
    }

    /// Modifier flags of the forwarded events.
    public var flags: CGEventFlags { self == .primaryWithOption ? .maskAlternate : [] }

    /// Short name for logs.
    public var logName: String {
        switch self {
        case .primary: "left"
        case .secondary: "right"
        case .primaryWithOption: "option-left"
        }
    }
}
