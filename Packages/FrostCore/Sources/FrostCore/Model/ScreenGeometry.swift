import AppKit

extension NSScreen {
    /// The screen's CoreGraphics display ID (`NSScreenNumber`); nil if AppKit doesn't report one.
    public var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
