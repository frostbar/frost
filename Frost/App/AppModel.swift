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
    /// Moves icons that new apps place in the Always Hidden section into the Hidden section.
    @ObservationIgnored let newItems: NewItemPlacer

    /// Opens the settings window on the given tab (nil keeps the current tab). Set by AppDelegate.
    @ObservationIgnored var showSettings: (_ tab: SettingsTab?) -> Void = { _ in }
    /// Opens the permissions onboarding window. Set by AppDelegate. Used by the "Permissions Required" placeholder
    /// and the grant buttons on the About tab.
    @ObservationIgnored var openOnboarding: () -> Void = {}
    /// Shows or hides the Frost Bar. Set by AppDelegate.
    @ObservationIgnored var toggleFrostBar: (_ includeAlwaysHidden: Bool) -> Void = { _ in }

    @ObservationIgnored private var opportunisticCapture: Task<Void, Never>?

    init() {
        preferences = Preferences()
        permissions = PermissionsService()
        scanner = MenuBarItemScanner()
        capturer = ItemImageCapturer()
        mover = ItemMover(scanner: scanner)
        sections = SectionController(preferences: preferences, permissions: permissions, scanner: scanner)
        newItems = NewItemPlacer(scanner: scanner, mover: mover, sections: sections, permissions: permissions)
        updates = UpdateController()
        presence = UserPresenceMonitor()
        sections.model = self
        mover.controlWindows = { [weak sections] in sections?.controlWindows }
        scanner.ownWindowIDs = { [weak sections] in sections?.controlWindows?.all ?? [] }
        scanner.controlFrames = { [weak sections] in sections?.controlFrames }
        capturer.menuBarDisplayID = { [weak scanner] in scanner?.menuBarDisplay?.id ?? CGMainDisplayID() }
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
    /// be drawn highlighted).
    func captureNaturallyVisibleItems() {
        guard opportunisticCapture == nil, permissions.screenRecording, !mover.isBusy, !sections.isEditing,
              sections.state != .collapsed, !ItemClicker.isMenuOnScreen() else { return }
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
