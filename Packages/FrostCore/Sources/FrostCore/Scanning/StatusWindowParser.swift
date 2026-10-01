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

    /// Reads all of the system's current status bar windows (including off-screen ones). Copies the description of
    /// every window in the session (hundreds; about 6 ms measured on a desktop with ~440 windows): polling loops that
    /// already know which windows they watch use `windows(withIDs:)` instead.
    public static func currentWindows() -> [RawStatusWindow] {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return parse(list)
    }

    /// The current state of the given status bar windows only (the same fields as `currentWindows()`, including
    /// off-screen windows; windows that no longer exist are left out). About ten times cheaper than
    /// `currentWindows()` for a handful of windows (0.6 ms vs. 6 ms measured), which matters in loops polling every
    /// 16–25 ms on the main thread.
    public static func windows<IDs: Collection>(withIDs ids: IDs) -> [RawStatusWindow] where IDs.Element == CGWindowID {
        // A CFArray of window IDs stored as raw pointer values (no retain / release callbacks); ID 0 doesn't exist.
        let pointers: [UnsafeRawPointer?] = ids.filter { $0 != 0 }.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard !pointers.isEmpty else { return [] }
        let array = pointers.withUnsafeBufferPointer { buffer in
            CFArrayCreate(kCFAllocatorDefault, UnsafeMutablePointer(mutating: buffer.baseAddress), buffer.count, nil)
        }
        return parse(CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] ?? [])
    }
}
