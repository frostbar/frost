import CoreGraphics
import ScreenCaptureKit

/// Reuses `SCShareableContent` (including off-screen windows): each fetch takes about 20–30 ms, and Frost Bar's live
/// refresh needs it twice per second (the freeze frame's displays, the strip capture's windows).
///
/// The cache is refetched when: a needed window is not in the cache (a new menu bar item), the set of displays
/// changes, or it is older than `maxAge`. Status item windows don't change while an app is running, so the cache is
/// valid most of the time; filters built by windowID use the cached `SCWindow` (measured on a VM: fetched while
/// collapsed, captures after expanding still work).
@MainActor
public final class ShareableContentCache {
    public static let maxAge: Duration = .seconds(30)

    private var content: SCShareableContent?
    private var windowIDs: Set<CGWindowID> = []
    private var displayIDs: Set<CGDirectDisplayID> = []
    private var fetchedAt: ContinuousClock.Instant?

    public init() {}

    /// Content that includes every window in `windows` (refetched when some are missing; they may still be missing
    /// after the refetch, so callers look windows up by windowID).
    public func content(containing windows: Set<CGWindowID> = []) async -> SCShareableContent? {
        if let content, let fetchedAt, ContinuousClock.now - fetchedAt < Self.maxAge,
           windows.isSubset(of: windowIDs), displayIDs == Self.activeDisplayIDs() {
            return content
        }
        return await refresh()
    }

    /// Discards the cache (e.g. when the display configuration changes).
    public func invalidate() {
        content = nil
        windowIDs = []
        displayIDs = []
        fetchedAt = nil
    }

    private func refresh() async -> SCShareableContent? {
        guard let fresh = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        else {
            invalidate()
            return nil
        }
        content = fresh
        windowIDs = Set(fresh.windows.map(\.windowID))
        displayIDs = Set(fresh.displays.map(\.displayID))
        fetchedAt = .now
        return fresh
    }

    private static func activeDisplayIDs() -> Set<CGDirectDisplayID> {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return Set(ids.prefix(Int(count)))
    }
}
