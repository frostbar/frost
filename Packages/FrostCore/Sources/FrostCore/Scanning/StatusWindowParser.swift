import CoreGraphics
import Foundation

public struct RawStatusWindow: Hashable, Sendable {
    public let windowID: CGWindowID
    public let frame: CGRect
    public let title: String
    public let isOnScreen: Bool

    public init(windowID: CGWindowID, frame: CGRect, title: String, isOnScreen: Bool) {
        self.windowID = windowID
        self.frame = frame
        self.title = title
        self.isOnScreen = isOnScreen
    }
}

public enum StatusWindowParser {
    /// kCGStatusWindowLevel
    public static let statusWindowLayer = 25

    public static func parse(_ infos: [[String: Any]]) -> [RawStatusWindow] {
        infos.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == statusWindowLayer,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            return RawStatusWindow(
                windowID: CGWindowID(number),
                frame: frame,
                title: info[kCGWindowName as String] as? String ?? "",
                isOnScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false
            )
        }
    }

    /// Reads all of the system's current status bar windows (including off-screen ones).
    public static func currentWindows() -> [RawStatusWindow] {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return parse(list)
    }
}
