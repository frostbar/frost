import AppKit

extension NSScreen {
    /// The screen's CoreGraphics display ID (`NSScreenNumber`); nil if AppKit doesn't report one.
    public var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Conversions between AppKit global coordinates (bottom-left origin; used only to place NSWindows and for NSEvent
/// locations) and CG global coordinates (top-left origin; CGWindowList, AX and CGEvent): `y = primary display
/// frame.maxY − y` for points, and the same of `maxY` for rects. The formula is its own inverse.
public enum ScreenCoordinates {
    public static func cgPoint(fromAppKit point: CGPoint, primaryScreenMaxY: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenMaxY - point.y)
    }

    public static func cgRect(fromAppKit rect: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenMaxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The primary display's (`NSScreen.screens.first`, the one with the origin) frame.maxY; 0 without screens.
    @MainActor public static var primaryScreenMaxY: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    @MainActor public static func cgPoint(fromAppKit point: CGPoint) -> CGPoint {
        cgPoint(fromAppKit: point, primaryScreenMaxY: primaryScreenMaxY)
    }

    @MainActor public static func cgRect(fromAppKit rect: CGRect) -> CGRect {
        cgRect(fromAppKit: rect, primaryScreenMaxY: primaryScreenMaxY)
    }

    /// CG -> AppKit (the inverse of `cgRect(fromAppKit:)`, same formula).
    @MainActor public static func appKitRect(fromCG rect: CGRect) -> CGRect {
        cgRect(fromAppKit: rect, primaryScreenMaxY: primaryScreenMaxY)
    }
}
