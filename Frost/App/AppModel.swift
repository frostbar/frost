import AppKit
import FrostCore
import Observation

/// Aggregates app-level state and services, and hosts navigation callbacks (no-ops until wired up).
@Observable
@MainActor
final class AppModel {
    let preferences: Preferences
    let permissions: PermissionsService
    let scanner: MenuBarItemScanner
    let capturer: ItemImageCapturer
    let mover: ItemMover
    let sections: SectionController
    /// Sparkle automatic updates.
    let updates: UpdateController
    /// Whether the user is at the Mac (display sleep, screen lock, session switch).
    let presence: UserPresenceMonitor
    /// Moves icons that new apps place in the Always Hidden section into the Hidden section, and icons re-added in
    /// another section back into the section the user keeps them in.
    @ObservationIgnored let newItems: NewItemPlacer

    /// Opens the settings window on the given tab (nil keeps the current tab). Set by AppDelegate.
    @ObservationIgnored var showSettings: (_ tab: SettingsTab?) -> Void = { _ in }
    /// Opens the permissions onboarding window. Set by AppDelegate. Used on first launch and by the Frost Bar's grant
    /// buttons; Settings requests permissions directly.
    @ObservationIgnored var openOnboarding: () -> Void = {}
    /// Shows or hides the Frost Bar. Set by AppDelegate.
    @ObservationIgnored var toggleFrostBar: (_ includeAlwaysHidden: Bool) -> Void = { _ in }

    @ObservationIgnored private var opportunisticCapture: Task<Void, Never>?

    /// Items behind the notch and when to capture them in the background (`FrostBarController+ObscuredCapture`).
    @ObservationIgnored var obscuredCapture = ObscuredCapturePolicy(launchedAt: .now)
    /// Called when items behind the notch may need a capture the background loop doesn't account for
    /// (`ObscuredCapturePolicy.shouldWake`): `noteExpandedScan` found new ones or known ones without a current capture,
    /// or the captures became invalid (an appearance change). Set by the Frost Bar, which runs the background captures.
    @ObservationIgnored var obscuredItemsChanged: () -> Void = {}

    /// A settled scan in an expanded or editing state: records which items it shows off screen (behind the notch, see
    /// `ObscuredCapturePolicy.obscured`). `expected`: the items that state shows (nil: unknown).
    func noteExpandedScan(expected: Set<CGWindowID>?) {
        let items = scanner.items
        let bounds = scanner.menuBarDisplay?.frame ?? CGDisplayBounds(CGMainDisplayID())
        let obscured = ObscuredCapturePolicy.obscured(in: items, expected: expected, displayBounds: bounds)
            .subtracting(sections.controlWindows?.all ?? [])
        let known = obscuredCapture.obscuredItems
        obscuredCapture.observe(obscured: obscured, visible: Set(items.filter(\.isOnScreen).map(\.windowID)),
                                now: .now)
        let added = obscured.subtracting(known)
        if !added.isEmpty {
            FrostLog.capture.notice("\(added.count) item(s) behind the notch (\(obscured.count) in all)")
        }
        let needing = permissions.canCaptureImages
            ? Set(capturer.missing(items.filter { obscured.contains($0.windowID) }).map(\.windowID)) : []
        guard obscuredCapture.shouldWake(.expandedScan(added: added, needingImages: needing)) else { return }
        obscuredItemsChanged()
    }

    /// The captures became invalid (`ItemImageCapturer.capturesInvalidated`): items behind the notch need new ones.
    private func capturesInvalidated() {
        guard obscuredCapture.shouldWake(.capturesInvalidated) else { return }
        FrostLog.capture.notice("captures invalidated; rescheduling the background capture of items behind the notch")
        obscuredItemsChanged()
    }

    init() {
        preferences = Preferences()
        permissions = PermissionsService()
        scanner = MenuBarItemScanner()
        capturer = ItemImageCapturer()
        mover = ItemMover(scanner: scanner)
        sections = SectionController(preferences: preferences, permissions: permissions, scanner: scanner)
        presence = UserPresenceMonitor()
        newItems = NewItemPlacer(scanner: scanner, mover: mover, sections: sections, permissions: permissions,
                                 preferences: preferences, presence: presence)
        updates = UpdateController()
        sections.model = self
        mover.controlWindows = { [weak sections] in sections?.controlWindows }
        mover.syntheticDragActive = { [weak sections] active in sections?.suppressIconHighlight(active) }
        scanner.ownWindowIDs = { [weak sections] in sections?.controlWindows?.all ?? [] }
        scanner.controlFrames = { [weak sections] in sections?.controlFrames }
        capturer.menuBarDisplayID = { [weak scanner] in scanner?.menuBarDisplay?.id ?? CGMainDisplayID() }
        capturer.capturesInvalidated = { [weak self] in self?.capturesInvalidated() }
    }

    /// Menu bar items in each of the three sections (left to right). Empty when the Frost control items are missing.
    var layout: MenuBarLayout {
        guard let controls = sections.controlWindows else { return [:] }
        return SectionAssigner.layout(of: scanner.items, controls: controls)
    }

    /// Opens the settings window. A nil `tab` keeps the window's current (or initial) tab.
    func openSettings(tab: SettingsTab? = nil) {
        showSettings(tab)
    }

    /// Called once the Hidden section has expanded in place (not a temporary Frost Bar expansion) and settled: captures
    /// the hidden items while they are on screen (also writing the disk cache) so the Frost Bar does not have to expand
    /// them temporarily later. Skipped while a move is in progress, while editing, or while a menu is open (an icon may
    /// be drawn highlighted). Items that don't fit are recorded for the background capture (`noteExpandedScan`).
    func captureNaturallyVisibleItems() {
        guard !mover.isBusy, !sections.isEditing, sections.state != .collapsed else { return }
        // Fully expanded, every item should be on screen; expanded, the Always Hidden items are pushed out by their
        // separator, so only items under the notch count.
        noteExpandedScan(expected: sections.state == .expandedAll ? Set(scanner.items.map(\.windowID)) : nil)
        guard opportunisticCapture == nil, permissions.screenRecording, !ItemClicker.isMenuOnScreen() else { return }
        let layout = layout
        let shown = layout[.hidden, default: []]
            + (sections.state == .expandedAll ? layout[.alwaysHidden, default: []] : [])
        let targets = shown.filter(\.isOnScreen)
        guard !targets.isEmpty else { return }
        opportunisticCapture = Task { [weak self] in
            await self?.capturer.capture(targets)
            self?.opportunisticCapture = nil
        }
    }

    func start() {
        presence.start()
        sections.install()
        scanner.start()
        newItems.start()
    }
}
