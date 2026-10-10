import CoreGraphics
import Foundation

/// Builds the menu bar item list on macOS 27 out of Accessibility, where there are no per-item status windows
/// (`MenuBarBackend.accessibility`).
///
/// On macOS 26 every status item is its own layer-25 window and `MenuBarItemScanner` reads CGWindowList, resolving
/// the owner through AX. On 27 `MenuBarAgent` draws the whole bar, so the window list has nothing to offer: the
/// extras' identities and geometry come from `kAXExtrasMenuBarAttribute` (`AXExtrasReader`), and the items keep
/// being addressed by a *synthesized* window ID, so everything above this file (sections, the layout editor, the
/// Frost Bar, captures) works on the same `MenuBarItem` values as on 26.
///
/// Two things differ from 26 and are deliberately not hidden from the user:
/// - the synthesized IDs are derived from the item's identity (`ItemIdentityKey`) instead of being handed out by the
///   window server, so they are stable across scans but mean nothing to the system;
/// - an item that is not drawn (pushed off the bar by a divider, see `BoundedDivider`) keeps reporting its previous
///   geometry for a while, so `isOnScreen` is a geometry estimate, never proof.
public enum AXMenuBarInventory {
    /// One of Frost's own status items. On 27 they are real `NSStatusItem`s of this process, so their frames come
    /// from AppKit directly (`button.window.frame`, converted to CG coordinates) and need no AX read.
    public struct OwnItem: Hashable, Sendable {
        /// The item's autosave name, which also becomes its identity (`ownWindowID`).
        public let autosaveName: String
        /// CG coordinates, top-left origin.
        public let frame: CGRect

        public init(autosaveName: String, frame: CGRect) {
            self.autosaveName = autosaveName
            self.frame = frame
        }
    }

    public struct Scan: Sendable {
        public let windows: [RawStatusWindow]
        public let ownership: [CGWindowID: AXItemInfo]

        public init(windows: [RawStatusWindow], ownership: [CGWindowID: AXItemInfo]) {
            self.windows = windows
            self.ownership = ownership
        }
    }

    /// The item list for one AX read, left to right, including Frost's own items.
    ///
    /// `axItems` is what `AXExtrasReader.readAll` returned (other processes only), `own` Frost's own status items.
    /// `displayBounds` is the display whose menu bar is managed (CG coordinates, top-left origin).
    public static func scan(axItems: [AXItemInfo], own: [OwnItem], displayBounds: CGRect) -> Scan {
        var windows: [RawStatusWindow] = []
        var ownership: [CGWindowID: AXItemInfo] = [:]

        for item in own where item.frame.width > 0 {
            let id = ownWindowID(autosaveName: item.autosaveName)
            windows.append(RawStatusWindow(windowID: id, frame: item.frame, title: item.autosaveName,
                                           isOnScreen: isOnScreen(item.frame, in: displayBounds)))
            ownership[id] = AXItemInfo(bundleID: Bundle.main.bundleIdentifier ?? "dev.frost.Frost", pid: getpid(),
                                       frame: item.frame, description: item.autosaveName)
        }

        for item in axItems {
            let id = windowID(bundleID: item.bundleID, identityKey: item.identityKey ?? "idx:?", pid: item.pid)
            // A title is what `SystemItemRules` falls back to when there is no AX identifier; on 27 it is also the
            // only human-readable name some items have, so the description is used when there is no title.
            let title = (item.title?.isEmpty == false) ? item.title! : (item.description ?? "")
            windows.append(RawStatusWindow(windowID: id, frame: item.frame, title: title,
                                           isOnScreen: isOnScreen(item.frame, in: displayBounds)))
            ownership[id] = item
        }

        // The system lays the bar out left to right; AX reports the same geometry, so this is also the order the
        // layout editor shows.
        windows.sort { ($0.frame.minX, $0.windowID) < ($1.frame.minX, $1.windowID) }
        return Scan(windows: windows, ownership: ownership)
    }

    /// Whether an item's frame lies on the managed display at all. Geometry only: an item pushed off the bar keeps
    /// its last reported frame for a while, and the AX frame of an overflowed item is stale, so this never proves
    /// that the item is drawn (`docs/macos-behavior.md`, "macOS 27").
    static func isOnScreen(_ frame: CGRect, in displayBounds: CGRect) -> Bool {
        frame.width > 0 && frame.maxX > displayBounds.minX && frame.minX < displayBounds.maxX
            && frame.maxY > displayBounds.minY && frame.minY < displayBounds.minY + menuBarRowSlack
    }

    /// How far below the display's top edge an item may still start and count as a menu bar item. Measured on
    /// macOS 27.0 (26A428): the extras sit at y = 1…3 with a height of 24…27, well inside this.
    static let menuBarRowSlack: CGFloat = 60

    /// Stable synthesized window ID of a third-party item: the same identity always maps to the same ID, so scans,
    /// the section memory and the Frost Bar agree on which item is which. `pid` is part of it because one app can
    /// have several items whose identity keys collide (`idx:0` of two apps can't, they carry different bundle IDs —
    /// but two *processes* of the same app can).
    public static func windowID(bundleID: String, identityKey: String, pid: pid_t) -> CGWindowID {
        id(from: "\(bundleID)\u{1}\(identityKey)\u{1}\(pid)")
    }

    /// Stable synthesized window ID of one of Frost's own status items.
    public static func ownWindowID(autosaveName: String) -> CGWindowID {
        id(from: "dev.frost.Frost\u{1}own\u{1}\(autosaveName)")
    }

    /// FNV-1a over the UTF-8 bytes, folded to 32 bits and kept off 0 (`StatusWindowParser` treats 0 as "no window")
    /// and off the range a real CG window ID can't have. 32 bits over a menu bar's worth of items makes a collision
    /// vanishingly unlikely, and a collision would only merge two tiles, never move the wrong item.
    static func id(from text: String) -> CGWindowID {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let folded = CGWindowID(truncatingIfNeeded: hash ^ (hash >> 32))
        return folded == 0 ? 1 : folded
    }
}
