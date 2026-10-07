import CoreGraphics
import Foundation

/// Keeps a window's top-left corner where the user last had it across closes, reopens and relaunches (the Settings
/// window, whose height follows the selected tab). Centering, or restoring the whole frame, would move the top edge
/// whenever the window reopens on a tab of a different height. AppKit coordinates (bottom-left origin).
public enum WindowTopLeft {
    /// The frame for a window of `size` whose top-left corner goes to `topLeft`, kept within the visible frame of the
    /// screen that contains `topLeft` (moved down / left if it would stick out). nil when no screen contains it (a
    /// display was disconnected): the caller centers the window instead.
    public static func frame(size: CGSize, topLeft: CGPoint, visibleFrames: [CGRect]) -> CGRect? {
        guard let screen = visibleFrames.first(where: { contains($0, topLeft) }) else { return nil }
        var origin = CGPoint(x: topLeft.x, y: topLeft.y - size.height)
        origin.x = min(max(origin.x, screen.minX), max(screen.minX, screen.maxX - size.width))
        origin.y = max(min(origin.y, screen.maxY - size.height), screen.minY)
        return CGRect(origin: origin, size: size)
    }

    /// A top-left corner on a screen's top or left edge counts as on it.
    private static func contains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x < rect.maxX && point.y > rect.minY && point.y <= rect.maxY
    }

    /// Stored as "x,y".
    public static func encode(_ point: CGPoint) -> String { "\(Double(point.x)),\(Double(point.y))" }

    public static func decode(_ string: String?) -> CGPoint? {
        guard let parts = string?.split(separator: ","), parts.count == 2,
              let x = Double(parts[0]), let y = Double(parts[1]), x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }
}
