import AppKit
import FrostCore
import Observation

/// Manages Frost's section boundaries and snowflake. macOS 26 uses three status items (left to right:
/// `[AH separator] [H separator] [Frost icon]`); macOS 27 adds a bounded companion at each boundary.
///
/// On macOS 26:
/// - collapsed: H and AH are both `length = 10_000` (clamped by the system to a 5016 pt window), pushing everything to
///   their left off screen.
/// - expanded: H is 0 (narrowed further to 1 pt with a constraint trick); AH stays 10_000.
/// - expandedAll: H and AH are both 0 (no line shown; the AH line only appears in the layout editor).
/// - isEditing: overrides the above; H and AH both show as thin vertical lines (`length = 8`).
@Observable
@MainActor
final class SectionController {
    typealias State = SectionState

    private(set) var state: State = .collapsed
    private(set) var isEditing = false
    /// Temporarily collapsed during editing to perform a move (see `whileCollapsedForMove`).
    @ObservationIgnored private var isSuspendedForMove = false
    /// A temporary expansion (Frost Bar live refresh) in progress: state changes requested meanwhile are recorded
    /// and applied by `restore` (see `TemporaryExpansion`).
    @ObservationIgnored private var temporaryExpansion: TemporaryExpansion?

    /// Set by AppModel; used for navigation callbacks (Settings, Frost Bar).
    @ObservationIgnored weak var model: AppModel?

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let permissions: PermissionsService
    @ObservationIgnored private let scanner: MenuBarItemScanner
    /// How the menu bar is managed here (`MenuBarBackend`): the wide separators of macOS 26 or the bounded dividers
    /// of macOS 27 (`BoundedDivider`).
    @ObservationIgnored let backend: MenuBarBackend

    @ObservationIgnored private var iconItem: NSStatusItem?
    @ObservationIgnored private var iconImageView: NSImageView?
    /// A dot on the Frost icon while an update found by a scheduled check awaits the user (`UpdateController`).
    @ObservationIgnored private var updateBadge: NSView?
    @ObservationIgnored private var hidden: SeparatorItem?
    @ObservationIgnored private var alwaysHidden: SeparatorItem?

    @ObservationIgnored private var rehideTask: Task<Void, Never>?
    /// Mouse monitors (global + local) that collapse immediately on an outside click while expanded inline.
    @ObservationIgnored private var outsideClickMonitors = EventMonitors()
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    /// The control item windows located last time. Window IDs don't change for the life of the process, so they're
    /// reused as long as they're still in the scan results.
    @ObservationIgnored private var locatedControls: FrostControlWindows?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    /// The display (active menu bar) the Frost icon's real window was last on.
    @ObservationIgnored private var iconDisplayID: CGDirectDisplayID?
    /// Multiple displays: clicks on a snowflake replica on another display that never reached the button
    /// (see `ReplicaClickDetector`).
    @ObservationIgnored private var replicaClicks = ReplicaClickDetector()
    @ObservationIgnored private var replicaClickMonitors = EventMonitors()
    @ObservationIgnored private var replicaClickTask: Task<Void, Never>?
    @ObservationIgnored private var screenParametersObserver: NSObjectProtocol?
    @ObservationIgnored private var displayRescanTask: Task<Void, Never>?
    /// The display setup last rescanned for: screen parameter notifications that don't change it (the Dock changing
    /// size) are ignored (`DisplayConfiguration`).
    @ObservationIgnored private var displayConfiguration: DisplayConfiguration?
    /// Environment variable `FROST_TEST_DROP_REPLICA_CLICKS=1` (VM testing only): drops replica clicks the system
    /// redelivers to the button, simulating a real Mac where the first click on a replica isn't delivered, to exercise
    /// the fallback path (the VM's virtual display redelivers, so it can't reproduce this otherwise).
    #if DEBUG
    private static let dropRedeliveredReplicaClicks =
        ProcessInfo.processInfo.environment["FROST_TEST_DROP_REPLICA_CLICKS"] == "1"
    #else
    private static let dropRedeliveredReplicaClicks = false
    #endif

    init(preferences: Preferences, permissions: PermissionsService, scanner: MenuBarItemScanner,
         backend: MenuBarBackend = .windowList) {
        self.preferences = preferences
        self.permissions = permissions
        self.scanner = scanner
        self.backend = backend
    }

    // MARK: - Installation

    /// The autosave names (and with them the identities) of Frost's control items.
    ///
    /// macOS 27 gets its own names: the 26 names are the keys of the saved *separator* positions, and reusing them
    /// would inherit a saved 5016 pt slot as a 27 divider's position. Items created under a fresh name land in the
    /// system's own slot and are placed by `OwnItemPlacer`.
    static let iconAutosaveName = FrostControlLocator.iconTitle
    static let hiddenAutosaveName = FrostControlLocator.hiddenSeparatorTitle
    static let alwaysHiddenAutosaveName = FrostControlLocator.alwaysHiddenSeparatorTitle
    static let accessibilityHiddenAutosaveName = "Frost27.HiddenDivider"
    static let accessibilityAlwaysHiddenAutosaveName = "Frost27.AlwaysHiddenDivider"

    var iconName: String { Self.iconAutosaveName }
    var hiddenName: String {
        backend == .accessibility ? Self.accessibilityHiddenAutosaveName : Self.hiddenAutosaveName
    }
    var alwaysHiddenName: String {
        backend == .accessibility ? Self.accessibilityAlwaysHiddenAutosaveName : Self.alwaysHiddenAutosaveName
    }

    /// Preferred Position seeds (smaller values are further right). Written only when the key doesn't exist:
    /// the icon sits right next to Control Center; existing third-party icons with a Preferred Position land between
    /// H and AH (the Hidden section).
    /// AH can't get a small value, or every existing icon would end up in Always Hidden. Icons without a Preferred
    /// Position (never ⌘-dragged, i.e. most of them) sort left of AH no matter its value: on the first run
    /// NewItemPlacer moves them to Hidden.
    static let seeds: [(name: String, position: Double)] = [
        (iconAutosaveName, 0), (hiddenAutosaveName, 1), (alwaysHiddenAutosaveName, 10_000),
    ]

    /// Symbol configuration for the snowflake: same size and weight as system menu bar glyphs (Wi-Fi, Control Center).
    static let iconSymbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)

    func install() {
        guard iconItem == nil else { return }
        let defaults = UserDefaults.standard
        // The 26 seeds are Preferred Positions, which decide where a separator appears. On 27 the system keeps the
        // order itself (`MenuBarAgent`) and ignores them, so writing them would only leave stale keys behind: the
        // dividers are placed by `OwnItemPlacer` instead.
        if backend == .windowList {
            for seed in Self.seeds {
                let key = "NSStatusItem Preferred Position \(seed.name)"
                guard defaults.object(forKey: key) == nil else { continue }
                defaults.set(seed.position, forKey: key)
                // First run: existing icons without a Preferred Position are placed left of AH (Always Hidden);
                // NewItemPlacer moves them to Hidden once Accessibility is granted (possibly only after granting
                // and relaunching, hence persisted).
                if seed.name == Self.alwaysHiddenAutosaveName { NewItemPlacer.markFirstRun(defaults: defaults) }
            }
        }

        // Creation order decides the slot a fresh item lands in, and it is the opposite way round on the two
        // backends (measured; see `docs/macos-behavior.md`, "macOS 27"):
        // - 26: icon -> H -> AH, created earlier = further right, i.e. AH ends up left of H, left of the icon.
        // - 27: a new item takes the first free slot of the trailing area, and a later item goes to its right, so
        //   the same "AH, H, icon" order is created back to front: AH, then H, then the icon.
        // Never call removeStatusItem on quit: it deletes the saved position.
        if backend == .accessibility {
            alwaysHidden = SeparatorItem(autosaveName: alwaysHiddenName, backend: backend)
            hidden = SeparatorItem(autosaveName: hiddenName, backend: backend)
        }
        let icon = makeIcon()
        iconItem = icon
        if let window = icon.button?.window {
            // When the active menu bar moves to another display, the real window moves with it: rescan right away
            // (both the frames in `items` and their display changed).
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let screen = self.iconWindow?.screen else { return }
                    let id = screen.displayID ?? 0
                    // Also fires when the status item is created (no screen -> main display): only record real
                    // display changes.
                    defer { self.iconDisplayID = id }
                    guard let previous = self.iconDisplayID, previous != id else { return }
                    FrostLog.sections.notice(
                        "the Frost icon moved from display \(previous) to \(id) (active menu bar changed); rescanning")
                    // The bounded dividers are sized from the display they are on: moving the active menu bar to a
                    // smaller display would leave them above its half-display bound, where the system ignores the
                    // width and collapsing hides nothing.
                    self.updateDividerWidthsForDisplay()
                    self.scanner.scheduleRescan(after: .milliseconds(100))
                }
            }
        }

        updateReplicaClickMonitors()
        displayConfiguration = .current
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateReplicaClickMonitors()
                let current = DisplayConfiguration.current
                guard current != self.displayConfiguration else { return }
                self.displayConfiguration = current
                self.rescanAfterDisplayChange()
            }
        }

        if backend != .accessibility {
            hidden = SeparatorItem(autosaveName: hiddenName, backend: backend)
            alwaysHidden = SeparatorItem(autosaveName: alwaysHiddenName, backend: backend)
        } else {
            resetDividerWidths()
        }
        applyLengths()
        settleAndRescan()
        trackUpdateReminder()
        // macOS 27: items created under a fresh name land in the system's first free slot (on a busy bar: behind the
        // overflow chevron), so Frost puts them where they belong. Needs Accessibility, which is also what the
        // section model and the layout editor need; without it the user can ⌘-drag the dividers themselves.
        if backend == .accessibility { schedulePlacement() }
    }

    // MARK: - Placing Frost's own items (macOS 27)

    @ObservationIgnored private var placementTask: Task<Void, Never>?

    private func schedulePlacement() {
        guard placementTask == nil, !hasPlacedOwnItems else { return }
        // Placement needs Accessibility, which the user may grant later (onboarding asks for it): watch for the grant
        // instead of giving up, or the snowflake and the dividers would stay in the slots a fresh item lands in —
        // behind the overflow chevron on a busy bar — until the next launch.
        observeAccessibilityForPlacement()
        placementTask = Task { [weak self] in
            for attempt in 1...Self.placementAttempts {
                let placed = await self?.placeOwnItemsWhenPossible()
                guard let self else { return }
                // Placement only counts as done when the items really ended up where they belong (read back from
                // Accessibility). A failed attempt is usually transient — the user's mouse was down, another move was
                // running, the layout editor was open — so it is retried a couple of times instead of leaving the
                // snowflake in the slot a fresh item lands in (behind the overflow chevron on a busy bar).
                if placed == true {
                    self.hasPlacedOwnItems = true
                    break
                }
                if Task.isCancelled { break }
                FrostLog.sections.notice("placement attempt \(attempt, privacy: .public) did not take; trying again")
                try? await Task.sleep(for: Self.placementRetryDelay)
            }
            self?.placementTask = nil
        }
    }

    /// Whether Frost's own items have been placed this launch (`placeOwnItems`).
    @ObservationIgnored private var hasPlacedOwnItems = false

    /// Re-runs placement when the Accessibility permission arrives (no-op once they are placed).
    private func observeAccessibilityForPlacement() {
        guard backend == .accessibility, !hasPlacedOwnItems else { return }
        withObservationTracking {
            _ = permissions.accessibility
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.permissions.accessibility { self.schedulePlacement() }
                self.observeAccessibilityForPlacement()
            }
        }
    }

    /// macOS 27 puts a freshly created status item in the first free slot of the trailing area instead of honouring
    /// a saved position. On a bar with a handful of icons that slot is the leftmost one, which is not where the
    /// macOS 26 layout has the snowflake (next to Control Center); on a busy bar it is behind the overflow chevron,
    /// where the user can't reach it at all. So Frost ⌘-drags its own items — never a third-party one — into place,
    /// which needs Accessibility only to *read* the bar; without it the user can drag the dividers themselves.
    @discardableResult
    private func placeOwnItemsWhenPossible() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(30)
        while !permissions.canManageItems {
            guard clock.now < deadline, !Task.isCancelled else {
                FrostLog.sections.notice("""
                    not placing Frost's own items yet: Accessibility is not granted (placement runs when it arrives), \
                    so the snowflake and the dividers stay where the system put them
                    """)
                return false
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return await placeOwnItems()
    }

    /// Places Frost's own items; returns whether they are where they belong (a false return is retried).
    private func placeOwnItems() async -> Bool {
        guard let model, iconItem != nil, !isEditing else { return false }
        // A collapsed divider is a very wide window: its center is nowhere near the slot the user sees, and the
        // items it pushed out are only readable with stale frames. Place with everything narrow, restore afterwards.
        hidden?.mode = .zero
        alwaysHidden?.mode = .zero
        defer { applyLengths() }

        // Place the snowflake immediately left of the system items, then align the narrow divider pairs with
        // the user's sections. Each own-item drag still requires a positive Frost hit at its current centre.
        let iconPlaced = await placeOwnItem(named: iconName, followedBy: .left(of: .trailingSystemItem), in: model)
        let boundariesPlaced = await alignAccessibilityBoundaries()
        await scanner.refreshOwnership()
        return iconPlaced && boundariesPlaced
    }

    /// Places each bounded pair at the boundary of the user's arrangement, with everything narrow. Merely
    /// consuming space at the far left can overflow arbitrary icons without hiding the requested section.
    @discardableResult
    func alignAccessibilityBoundaries() async -> Bool {
        guard backend == .accessibility, let model, !model.mover.isBusy,
              let hiddenName2 = hidden?.companionName, let alwaysHiddenName2 = alwaysHidden?.companionName
        else { return backend != .accessibility }
        return await revealingForMove {
            await scanner.refreshOwnership()
            let iconX = ownItems().first { $0.autosaveName == iconName }?.frame.minX ?? .greatestFiniteMagnitude
            let visible = model.layout[.visible, default: []].first { $0.frame.minX < iconX }
            let h = await placeOwnItem(named: hiddenName, followedBy: .item(visible?.windowID ?? ownID(iconName)), in: model)
            let hp = await placeOwnItem(named: hiddenName2, followedBy: .right(ofOwnItem: hiddenName), in: model)
            await scanner.refreshOwnership()
            let firstHidden = model.layout[.hidden, default: []].first?.windowID ?? ownID(hiddenName)
            let a = await placeOwnItem(named: alwaysHiddenName, followedBy: .item(firstHidden), in: model)
            let ap = await placeOwnItem(named: alwaysHiddenName2, followedBy: .right(ofOwnItem: alwaysHiddenName), in: model)
            return h && hp && a && ap
        }
    }

    /// What a placed item must end up next to.
    private indirect enum PlacementAnchor {
        case item(CGWindowID)
        /// Immediately left of the trailing system items (the clock, the Control Center button).
        case trailingSystemItem
        /// Immediately left of the leftmost item of another app: the left end of the trailing area.
        case leftmostItem
        /// Immediately right of one of Frost's own items.
        case right(ofOwnItem: String)

        /// Immediately left of the leftmost of `kind`.
        static func left(of kind: PlacementAnchor) -> PlacementAnchor { kind }
    }

    /// ⌘-drags one of Frost's own status items until it sits immediately left of its anchor. Status items snap to
    /// slots, and a ⌘-drag lands a little left of where the mouse-up was posted (the items on that side slide over
    /// while the item is lifted), so the requested x is corrected by what the previous attempt missed by — up to
    /// `placementAttempts` times. Runs inside `ItemMover.transaction`, like every other move.
    @discardableResult
    private func placeOwnItem(named name: String, followedBy anchor: PlacementAnchor, in model: AppModel) async -> Bool {
        placementCorrection = 0
        for attempt in 1...Self.placementAttempts {
            await scanner.refreshOwnership()
            guard ownItems().contains(where: { $0.autosaveName == name }) else { return false }
            guard let target = placementTarget(of: anchor) else {
                FrostLog.sections.notice("not placing \(name, privacy: .public): its anchor is unknown")
                return false
            }
            if placementIsSatisfied(itemID: ownID(name), anchor: anchor) {
                FrostLog.sections.notice("\(name, privacy: .public) is already in place")
                return true
            }
            let request = target + placementCorrection
            guard let landed = await dragOwnItem(named: name, toX: request, in: model) else { return false }
            placementCorrection = target - landed
            FrostLog.sections.notice("""
                placing \(name, privacy: .public): asked for x \(Int(request), privacy: .public), landed at \
                \(Int(landed), privacy: .public) (attempt \(attempt, privacy: .public))
                """)
        }
        return placementIsSatisfied(itemID: ownID(name), anchor: anchor)
    }

    /// How far the last placement missed by; added to the next request (the drag's landing lags the request).
    @ObservationIgnored private var placementCorrection: CGFloat = 0

    static let placementAttempts = 3
    static let placementRetryDelay: Duration = .seconds(5)

    private func ownID(_ name: String) -> CGWindowID { AXMenuBarInventory.ownWindowID(autosaveName: name) }

    private func placementTargetID(of anchor: PlacementAnchor) -> CGWindowID? {
        switch anchor {
        case .item(let id): return id
        case .right(let name): return ownID(name)
        case .trailingSystemItem: return trailingSystemAnchor()?.windowID
        case .leftmostItem: return leftmostItem()?.windowID
        }
    }

    /// The x the item's center is dragged to.
    private func placementTarget(of anchor: PlacementAnchor) -> CGFloat? {
        switch anchor {
        case .item(let id): return scanner.items.first { $0.windowID == id }?.frame.minX
        case .right(let name): return ownItems().first { $0.autosaveName == name }?.frame.maxX
        case .trailingSystemItem: return trailingSystemAnchor()?.frame.minX
        case .leftmostItem: return leftmostItem()?.frame.minX
        }
    }

    /// Whether the item ended up against its anchor, on the side it belongs (`OwnItemPlacement`).
    private func placementIsSatisfied(itemID: CGWindowID, anchor: PlacementAnchor) -> Bool {
        guard let nextID = placementTargetID(of: anchor),
              let item = scanner.items.first(where: { $0.windowID == itemID }),
              let anchorItem = scanner.items.first(where: { $0.windowID == nextID })
        else { return false }
        let side: OwnItemPlacement.Side = switch anchor {
        case .right: .right
        case .trailingSystemItem, .leftmostItem, .item: .left
        }
        return OwnItemPlacement.isSatisfied(item: item.frame, anchor: anchorItem.frame, side: side)
    }

    /// The leftmost item of another app: the left end of the trailing area.
    private func leftmostItem() -> MenuBarItem? {
        let ownIDs = Set(ownItems().map { ownID($0.autosaveName) })
        return scanner.items.filter { !ownIDs.contains($0.windowID) && $0.frame.width > 0 }
            .min { $0.frame.minX < $1.frame.minX }
    }

    /// The item the snowflake belongs immediately left of (`SystemItemAnchor`).
    private func trailingSystemAnchor() -> MenuBarItem? {
        let ownIDs = Set(ownItems().map { ownID($0.autosaveName) })
        let display = scanner.menuBarDisplay?.frame ?? CGDisplayBounds(CGMainDisplayID())
        return SystemItemAnchor.trailingAnchor(among: scanner.items, own: ownIDs, displayBounds: display)
    }

    /// ⌘-drags one of Frost's own status items to `toX`; returns where it landed (nil when nothing was posted).
    private func dragOwnItem(named name: String, toX: CGFloat, in model: AppModel) async -> CGFloat? {
        guard !model.mover.isBusy,
              let item = ownItems().first(where: { $0.autosaveName == name }) else { return nil }
        let center = CGPoint(x: item.frame.midX, y: item.frame.midY)
        // The mouse-down has to land on *this* item. Its window frame is what AppKit reports, and on a crowded bar the
        // item can be in the system's overflow, or still moving after the dividers shrank — posting at a stale centre
        // would press whatever is there, which may be another app's icon. So the system is asked which process owns
        // the element at that point, exactly as `ItemMover.moveDirect` does for a third-party item.
        switch await Task.detached(operation: { AXExtrasReader.processAt(center) }).value {
        case getpid():
            break
        case let other?:
            FrostLog.sections.notice("""
                not placing \(name, privacy: .public): the point (\(Int(center.x), privacy: .public),                 \(Int(center.y), privacy: .public)) belongs to process \(other, privacy: .public), not to Frost
                """)
            return nil
        case nil:
            FrostLog.sections.notice("""
                not placing \(name, privacy: .public): Accessibility does not report an element at                 (\(Int(center.x), privacy: .public), \(Int(center.y), privacy: .public))
                """)
            return nil
        }
        do {
            return try await model.mover.transaction {
                let result = await Task.detached {
                    OwnItemDrag.post(itemCenter: center, toX: toX)
                }.value
                guard let result, result.posted else {
                    FrostLog.sections.notice("placement of \(name, privacy: .public) not posted: the mouse is busy")
                    return nil
                }
                // The order settles over a few frames; read it back before judging where it landed.
                var landed: CGFloat?
                for _ in 0..<6 {
                    try? await Task.sleep(for: .milliseconds(150))
                    await scanner.refreshOwnership()
                    landed = ownItems().first { $0.autosaveName == name }?.frame.midX
                }
                return landed
            }
        } catch {
            FrostLog.sections.error("placing \(name, privacy: .public) failed: \(error, privacy: .public)")
            return nil
        }
    }

    /// Frost's own status items with their current frames (`AXMenuBarInventory.OwnItem`), for the scanner's
    /// Accessibility source: on 27 no window list can tell Frost where its own icon and dividers are.
    func ownItems() -> [AXMenuBarInventory.OwnItem] {
        var result: [AXMenuBarInventory.OwnItem] = []
        if let frame = iconItem?.button?.window.map({ ScreenCoordinates.cgRect(fromAppKit: $0.frame) }) {
            result.append(AXMenuBarInventory.OwnItem(autosaveName: iconName, frame: frame))
        }
        if let frame = hidden?.cgFrame { result.append(.init(autosaveName: hiddenName, frame: frame)) }
        if let frame = alwaysHidden?.cgFrame { result.append(.init(autosaveName: alwaysHiddenName, frame: frame)) }
        for divider in [hidden, alwaysHidden].compactMap({ $0 }) {
            if let name = divider.companionName, let frame = divider.companion?.cgFrame {
                result.append(.init(autosaveName: name, frame: frame))
            }
        }
        return result
    }

    /// Unsupported macOS (`AppModel.isMenuBarSupported`): only the snowflake, whose clicks show its menu with the
    /// notice. The separators are not created, so the menu bar stays as the system arranges it; their saved Preferred
    /// Positions are kept (never `removeStatusItem`) for a version that supports this macOS. Only the icon's seed is
    /// written (next to Control Center); the separators' seeds and the first-run mark are left to that version.
    func installNoticeOnly() {
        guard iconItem == nil else { return }
        isManagingMenuBar = false
        let key = "NSStatusItem Preferred Position \(Self.iconAutosaveName)"
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(Self.seeds[0].position, forKey: key)
        }
        iconItem = makeIcon()
        trackUpdateReminder()
    }

    /// Whether Frost manages the menu bar (separators, sections, the Frost Bar); false on an unsupported macOS
    /// (`installNoticeOnly`).
    @ObservationIgnored private(set) var isManagingMenuBar = true

    /// The snowflake status item, with its own image view and the update badge.
    private func makeIcon() -> NSStatusItem {
        let icon = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        icon.autosaveName = Self.iconAutosaveName
        icon.isVisible = true
        if let button = icon.button {
            button.setAccessibilityLabel("Frost")
            button.target = self
            button.action = #selector(iconClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // NSButton doesn't expose its internal image view; add our own to control symbol size and centering.
            let imageView = NSImageView()
            imageView.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Frost")
            // The status bar button configures a `button.image` symbol to the menu bar glyph size, but not our own
            // image view: unconfigured, the snowflake looks noticeably smaller and thinner than neighboring Wi-Fi or
            // third-party icons. (SF Symbols are template images and follow the menu bar's appearance.)
            imageView.symbolConfiguration = Self.iconSymbolConfiguration
            imageView.imageScaling = .scaleNone
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.setAccessibilityElement(false)
            button.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
            iconImageView = imageView
            let badge = NSView()
            badge.wantsLayer = true
            badge.layer?.cornerRadius = Self.updateBadgeSize / 2
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.isHidden = true
            badge.setAccessibilityElement(false)
            button.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.widthAnchor.constraint(equalToConstant: Self.updateBadgeSize),
                badge.heightAnchor.constraint(equalToConstant: Self.updateBadgeSize),
                badge.centerXAnchor.constraint(equalTo: imageView.trailingAnchor),
                badge.centerYAnchor.constraint(equalTo: imageView.topAnchor, constant: 1),
            ])
            updateBadge = badge
        }
        return icon
    }

    // MARK: - Update reminder

    static let updateBadgeSize: CGFloat = 6

    /// Shows the update badge (and says so to VoiceOver) while `UpdateController.pendingUpdateVersion` is set.
    private func trackUpdateReminder() {
        let pending = withObservationTracking {
            model?.updates.pendingUpdateVersion != nil
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.trackUpdateReminder() }
        }
        updateBadge?.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        updateBadge?.isHidden = !pending
        iconItem?.button?.setAccessibilityLabel(pending
            ? String(localized: "Frost, update available",
                     comment: "Accessibility label of the Frost menu bar icon while an update is waiting to be installed")
            : "Frost")
    }

    // MARK: - Control item windows

    /// Window IDs of Frost's three control items in the scan results (`button.window.windowNumber` is not a CG window ID).
    /// Matched by button window frame (converted to CG coordinates), falling back to the window title; returns a
    /// value only if all three are found.
    var controlWindows: FrostControlWindows? {
        // macOS 27: Frost's own items are identified by the names they were created with. The locator below matches
        // by frame or by title, and on 27 neither is dependable for them — a divider held as a thin line reports an
        // Accessibility frame that differs from its window's, and the 26 titles are not the ones in use — so the
        // three IDs are derived from the names directly instead.
        if backend == .accessibility {
            guard ownItemNames != nil else { return nil }
            return FrostControlWindows(icon: ownID(iconName), hiddenSeparator: ownID(hiddenName),
                                       alwaysHiddenSeparator: ownID(alwaysHiddenName))
        }
        let items = scanner.items
        if let locatedControls, locatedControls.all.isSubset(of: Set(items.map(\.windowID))) {
            return locatedControls
        }
        let located = FrostControlLocator.locate(
            in: items,
            iconFrame: iconItem?.button?.window.map { ScreenCoordinates.cgRect(fromAppKit: $0.frame) },
            hiddenFrame: hidden?.cgFrame,
            alwaysHiddenFrame: alwaysHidden?.cgFrame,
            titles: (iconName, hiddenName, alwaysHiddenName))
        locatedControls = located
        return located
    }

    /// CG frames of the real windows of Frost's three control items (the scanner uses them to find the display with the
    /// active menu bar and to tell replicas on other displays apart).
    var controlFrames: FrostControlFrames? {
        guard iconItem != nil else { return nil }
        return FrostControlFrames(icon: iconItem?.button?.window.map { ScreenCoordinates.cgRect(fromAppKit: $0.frame) },
                                  hidden: hidden?.cgFrame, alwaysHidden: alwaysHidden?.cgFrame)
    }

    /// The status bar window holding the Frost icon button (the Frost Bar positions itself by it and checks whether a
    /// click landed on the icon).
    ///
    /// Multiple displays: this is the **real** window, always on the display with the active menu bar (it moves to
    /// whichever display's menu bar the user clicks or focuses; other displays show replicas, see
    /// `MenuBarDisplayResolver`). Clicking the snowflake on a secondary display first moves the real window there, then
    /// (in a VM) redelivers the click to it, so the Frost Bar opens under the clicked snowflake. On a real Mac the click
    /// may not reach the button (first click does nothing); `ReplicaClickDetector` detects and replays it
    /// (`replicaClickMonitors`).
    var iconWindow: NSWindow? { iconItem?.button?.window }

    // MARK: - State

    /// Switches to `newState` (while editing, only records it without changing the appearance). During a temporary
    /// expansion only records the request: `restore` ends in it, so the freeze frame is removed only once the
    /// requested state is confirmed.
    func setState(_ newState: State) {
        if temporaryExpansion != nil {
            temporaryExpansion?.request(newState)
            FrostLog.sections.notice("state \(newState.rawValue) requested during a temporary expansion; applied when it ends")
            return
        }
        state = newState
        guard !isEditing else { return }
        applyLengths()
        settleAndRescan()
        if newState == .collapsed { cancelAutoRehide() } else { armAutoRehide() }
    }

    func beginEditing() {
        cancelAutoRehide()
        isEditing = true
        applyLengths()
        settleAndRescan()
    }

    /// Ends editing and collapses. If a move transaction is in progress, the caller (LayoutEditorModel) should await it first.
    func endEditing() {
        model?.rememberAccessibilityOrder()
        isEditing = false
        setState(.collapsed)
    }

    /// Runs `body` with the menu bar temporarily collapsed (separators pushed out) during editing, then restores the
    /// editing state; both switches wait for frames to settle and rescan.
    ///
    /// On a crowded notched display, items that don't fit in editing state are tucked under the notch, so their x doesn't
    /// reflect the real order and moves can't be verified (on a real Mac they also fail silently). Collapsed, everything
    /// to the left is pushed off screen together, the order is reliable, and moves routed by window ID complete and
    /// verify normally. Outside editing, runs `body` directly.
    func whileCollapsedForMove<T>(_ body: () async throws -> T) async rethrows -> T {
        guard isEditing, !isSuspendedForMove else { return try await body() }
        isSuspendedForMove = true
        applyLengths()
        await waitForSettle()
        scanner.rescan()
        do {
            let result = try await body()
            await resumeEditingAfterMove()
            return result
        } catch {
            await resumeEditingAfterMove()
            throw error
        }
    }

    private func resumeEditingAfterMove() async {
        isSuspendedForMove = false
        applyLengths()
        await waitForSettle()
        scanner.rescan()
    }

    /// Runs `body` with every item drawn (both dividers take no width) and restores the section state afterwards;
    /// the macOS 27 counterpart of `whileCollapsedForMove`.
    ///
    /// A move on 27 starts on the item itself, and a hidden item keeps reporting the frame it had before it left the
    /// bar, so the drag would start in the wrong place. Everything is drawn for the duration of the move, which also
    /// makes the neighbours the destination is computed against the ones the user sees. No-op on 26, where the
    /// window list is reliable with the sections collapsed.
    func revealingForMove<T>(_ body: () async throws -> T) async rethrows -> T {
        guard backend == .accessibility, !isRevealedForMove else { return try await body() }
        isRevealedForMove = true
        applyLengths()
        await waitForSettle()
        scanner.rescan()
        do {
            let result = try await body()
            await endRevealForMove()
            return result
        } catch {
            await endRevealForMove()
            throw error
        }
    }

    /// Puts the dividers back to the section state after a move that needed everything drawn.
    private func endRevealForMove() async {
        model?.rememberAccessibilityOrder()
        isRevealedForMove = false
        applyLengths()
        await waitForSettle()
        scanner.rescan()
    }

    /// Whether the dividers are currently held narrow for a move (`revealingForMove`).
    @ObservationIgnored private var isRevealedForMove = false
    var usesLiveAccessibilityOrder: Bool { isEditing || isRevealedForMove || state == .expandedAll }

    /// Temporarily expands to at least `target` and waits for frames to settle (fast detection via `waitForFastSettle`,
    /// used by the Frost Bar's live refresh under the freeze frame, so faster is better). Returns the previous state for
    /// `restore(_:)` and whether the change was confirmed applied and settled (false on timeout: items aren't on screen
    /// yet and the caller shouldn't capture). Doesn't arm auto-rehide. While editing, or if already expanded enough,
    /// changes nothing (`settled` is true).
    func temporarilyExpand(_ target: State) async -> (previous: State, settled: Bool) {
        let original = state
        guard !isEditing, temporaryExpansion == nil, target > original else { return (original, true) }
        cancelAutoRehide()
        let baseline = statusFrames()
        temporaryExpansion = TemporaryExpansion(prior: original)
        state = target
        applyLengths()
        let settled = await waitForFastSettle(baseline: baseline, timeout: Self.expandSettleTimeout)
        scanner.rescan()
        return (original, settled)
    }

    /// Ends the temporary expansion and waits to settle; returns whether the final state was confirmed applied. The
    /// final state is `previous` (the state before `temporarilyExpand`), unless the user asked for another one
    /// meanwhile (e.g. clicked the Frost icon on a display that expands in the menu bar): then that one, so their click
    /// is neither lost nor undone. Collapsing occasionally takes a few hundred ms to apply (about 0.5 s measured in a
    /// VM, with the separators still at expanded length meanwhile), and the freeze frame must stay until then, so the
    /// timeout is longer than expanding (the Frost Bar passes as much as its freeze frame allows).
    @discardableResult
    func restore(_ previous: State, timeout: Duration = SectionController.restoreSettleTimeout) async -> Bool {
        let expansion = temporaryExpansion
        temporaryExpansion = nil
        let target = expansion?.finalState ?? previous
        if let expansion, expansion.requested != nil {
            FrostLog.sections.notice("""
                ending a temporary expansion in state \(target.rawValue) requested meanwhile \
                (was \(expansion.prior.rawValue))
                """)
        }
        guard !isEditing else {
            state = target
            return true
        }
        guard target != state else {
            // Already in the final state (the user asked for the temporary one): nothing to wait for.
            if expansion != nil, target != .collapsed { armAutoRehide() }
            return true
        }
        let baseline = statusFrames()
        state = target
        applyLengths()
        if target != .collapsed { armAutoRehide() }
        let settled = await waitForFastSettle(baseline: baseline, timeout: timeout)
        scanner.rescan()
        return settled
    }

    static let expandSettleTimeout: Duration = .milliseconds(500)
    static let restoreSettleTimeout: Duration = .milliseconds(1500)

    private func applyLengths() {
        guard let hidden, let alwaysHidden else { return }
        if isRevealedForMove {
            hidden.mode = .zero
            alwaysHidden.mode = .zero
            return
        }
        if backend == .accessibility {
            hidden.collapseWidth = model?.layout[.hidden, default: []].isEmpty == false ? hiddenCollapseWidth : 0
            alwaysHidden.collapseWidth = model?.layout[.alwaysHidden, default: []].isEmpty == false ? alwaysHiddenCollapseWidth : 0
        }
        if isEditing && isSuspendedForMove {
            hidden.mode = .pushOut
            alwaysHidden.mode = .pushOut
            return
        }
        if isEditing {
            // Both backends draw every item while the layout editor is open and show the section boundaries as thin
            // lines. On 27 that is not just cosmetic: an item the bar isn't drawing keeps reporting the frame it had
            // before it left, so the editor's sections and the neighbours a drop is resolved against are only true
            // while everything is drawn.
            hidden.mode = .line
            alwaysHidden.mode = .line
            return
        }
        applySectionLengths()
    }

    private func applySectionLengths() {
        guard let hidden, let alwaysHidden else { return }
        if backend == .windowList {
            hidden.collapseWidth = SeparatorItem.pushOutLength
            alwaysHidden.collapseWidth = SeparatorItem.pushOutLength
        }
        switch state {
        case .collapsed:
            hidden.mode = .pushOut
            alwaysHidden.mode = .pushOut
        case .expanded:
            hidden.mode = .zero
            alwaysHidden.mode = .pushOut
        case .expandedAll:
            hidden.mode = .zero
            alwaysHidden.mode = .zero
        }
    }

    // MARK: - How much of the bar the dividers take (macOS 27)

    /// Width of the Hidden divider when its section is collapsed: how many icons leave the bar (see
    /// `BoundedDivider`: wider means fewer icons drawn, never "this exact icon is hidden").
    @ObservationIgnored private var hiddenCollapseWidth: CGFloat = 0
    /// The same for the Always Hidden divider.
    @ObservationIgnored private var alwaysHiddenCollapseWidth: CGFloat = 0

    /// Sizes the bounded dividers from the display the menu bar is on (`BoundedDivider.collapseWidth`): a width
    /// above half of it is ignored by the system, so a display change has to resize them or collapsing stops hiding
    /// anything.
    private func updateDividerWidthsForDisplay() {
        guard backend == .accessibility, hidden != nil else { return }
        resetDividerWidths()
        applyLengths()
    }

    /// The names of Frost's own status items, including both companion dividers on macOS 27.
    private var ownItemNames: [String]? {
        let names = ownItems().map(\.autosaveName)
        return names.count == (backend == .accessibility ? 5 : 3) ? names : nil
    }

    static func clampDividerWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, BoundedDivider.minimumUsefulWidth), BoundedDivider.absoluteCap)
    }

    /// The starting widths of the bounded dividers on 27, from the display they are on.
    private func resetDividerWidths() {
        let width = BoundedDivider.collapseWidth(displayWidth: menuBarWidth) ?? BoundedDivider.minimumUsefulWidth
        hiddenCollapseWidth = width
        alwaysHiddenCollapseWidth = width
    }

    // MARK: - Waiting to settle

    /// Polls the CG frames of Frost's control item windows every 50 ms until two polls match (min 100 ms, timeout 500 ms).
    /// Measured: a length change applies after 55-61 ms and settles after 108-118 ms. To avoid declaring it settled
    /// before the change applies, the snapshot must also differ from the pre-change baseline before 250 ms. Only Frost's
    /// own windows are checked: other apps' icons may keep changing (width follows content), so "two matching polls"
    /// might never happen; items pushed around update in the same layout pass as the separators.
    func waitForSettle(baseline: [CGWindowID: CGRect]? = nil) async {
        let clock = ContinuousClock()
        let start = clock.now
        let baseline = baseline ?? statusFrames()
        var previous: [CGWindowID: CGRect]?
        while clock.now - start < .milliseconds(500) {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            let current = statusFrames()
            let elapsed = clock.now - start
            if elapsed >= .milliseconds(100), current == previous,
               current != baseline || elapsed >= .milliseconds(250) {
                return
            }
            previous = current
        }
    }

    /// Fast settle detection: polls the control item frames about every 16 ms and returns true once the change has
    /// applied (differs from `baseline`) and two polls match (`SettleDetector`), with no minimum wait; returns false if
    /// not confirmed within `timeout`. Frames are also checked around captures (`ItemImageCapturer` recaptures items
    /// that are still moving).
    func waitForFastSettle(baseline: [CGWindowID: CGRect], timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var detector = SettleDetector(baseline: baseline)
        while clock.now < deadline {
            do { try await Task.sleep(for: Self.fastSettlePoll) } catch { return false }
            if detector.observe(statusFrames()) { return true }
        }
        FrostLog.sections.error("the menu bar did not settle within \(timeout, privacy: .public) after changing sections")
        return false
    }

    static let fastSettlePoll: Duration = .milliseconds(16)

    /// Width of the menu bar Frost manages, for the bounded divider widths of macOS 27.
    private var menuBarWidth: CGFloat {
        if let width = iconItem?.button?.window?.screen?.frame.width, width > 0 { return width }
        if let width = scanner.menuBarDisplay?.frame.width, width > 0 { return width }
        return CGDisplayBounds(CGMainDisplayID()).width
    }

    /// CG frames of Frost's control item windows; before the controls are located, all status windows on the scanned
    /// menu bar row (the display with the active menu bar).
    ///
    /// On 27 only Frost's own items exist as windows at all, and their frames are read from AppKit directly, so
    /// waiting for the bar to settle needs no window list and no Accessibility.
    private func statusFrames() -> [CGWindowID: CGRect] {
        if backend == .accessibility {
            return Dictionary(uniqueKeysWithValues: ownItems().map {
                (AXMenuBarInventory.ownWindowID(autosaveName: $0.autosaveName), $0.frame)
            })
        }
        let windows: [RawStatusWindow]
        if let ids = locatedControls?.all {
            windows = StatusWindowParser.windows(withIDs: ids)
        } else {
            let row = scanner.menuBarDisplay?.frame ?? CGDisplayBounds(CGMainDisplayID())
            windows = StatusWindowParser.currentWindows().filter { abs($0.frame.minY - row.minY) < 1 }
        }
        return Dictionary(windows.map { ($0.windowID, $0.frame) }, uniquingKeysWith: { a, _ in a })
    }

    /// After a state change, waits to settle and then rescans so `scanner.items` (and `AppModel.layout`) reflect the
    /// new positions.
    private func settleAndRescan() {
        let baseline = statusFrames()
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            await self?.waitForSettle(baseline: baseline)
            guard !Task.isCancelled, let self else { return }
            self.scanner.rescan()
            // Expanded inline, hidden items are on screen: capture them to keep the image cache (incl. disk) fresh.
            if self.state != .collapsed, !self.isEditing { self.model?.captureNaturallyVisibleItems() }
        }
    }

    // MARK: - Auto-rehide

    private func armAutoRehide() {
        cancelAutoRehide()
        guard preferences.autoRehide, !isEditing else { return }
        let delay = preferences.autoRehideDelay
        rehideTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            // Don't collapse while a menu is open (e.g. the user is in the menu of a just-revealed icon) or the
            // mouse is in the menu bar: check again later.
            while self?.shouldDeferAutoRehide == true {
                do { try await Task.sleep(for: Self.autoRehideRecheck) } catch { return }
            }
            guard let self, !self.isEditing, self.state != .collapsed else { return }
            self.setState(.collapsed)
        }
        outsideClickMonitors.add(
            matching: .leftMouseDown,
            // Clicks in other apps.
            global: { [weak self] event in
                guard !SyntheticEvents.isPostedByFrost(event) else { return }
                self?.outsideClick(at: NSEvent.mouseLocation)
            },
            // Clicks in Frost's own windows (Settings, onboarding). Frost's status items (snowflake, separators) are in
            // the menu bar and excluded by `outsideClick`; clicking the snowflake toggles via `handleIconClick`.
            local: { [weak self] event in
                guard !SyntheticEvents.isPostedByFrost(event) else { return }
                let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation
                self?.outsideClick(at: point, in: event.window)
            })
    }

    /// A click outside the menu bar (AppKit global coordinates): collapse. `window` is the Frost window of a local
    /// event (status item windows don't count as outside).
    private func outsideClick(at point: NSPoint, in window: NSWindow? = nil) {
        guard !isEditing, state != .collapsed, !isInMenuBar(point) else { return }
        if let window, window.className.contains("StatusBar") { return }
        setState(.collapsed)
    }

    private static let autoRehideRecheck: Duration = .seconds(2)

    private var shouldDeferAutoRehide: Bool {
        ItemClicker.isMenuOnScreen() || isInMenuBar(NSEvent.mouseLocation)
    }

    private func cancelAutoRehide() {
        rehideTask?.cancel()
        rehideTask = nil
        outsideClickMonitors.removeAll()
    }

    /// Whether a point (AppKit global coordinates) is inside the menu bar of its screen. The menu bar height is computed
    /// from the screen (`frame.maxY - visibleFrame.maxY`; 39 on notched displays), not `NSStatusBar.system.thickness`
    /// (which returns 22).
    private func isInMenuBar(_ point: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) })
        else { return false }
        return point.y >= screen.frame.maxY - menuBarHeight(of: screen)
    }

    private func menuBarHeight(of screen: NSScreen) -> CGFloat {
        PanelPlacement.menuBarHeight(screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                                     fallback: iconItem?.button?.window?.frame.height ?? 24)
    }

    // MARK: - Frost icon

    @objc private func iconClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        // Unsupported macOS: every click shows the menu with the notice; nothing toggles.
        guard isManagingMenuBar else {
            showMenu()
            return
        }
        if Self.dropRedeliveredReplicaClicks, replicaClicks.hasPendingClick {
            FrostLog.sections.notice("test: dropping the redelivered click on the replica (FROST_TEST_DROP_REPLICA_CLICKS)")
            return
        }
        guard replicaClicks.actionReceived(eventTime: event.timestamp) else {
            // This click was already replayed by `fireReplicaClickIfDue` (the system delivered it to the button late):
            // don't toggle again.
            FrostLog.sections.notice("ignoring a late Frost icon action for a replica click that was already handled")
            return
        }
        // MenuBarAgent can redeliver a 27 status-item action without the held modifier flags. Preserve the
        // event's flags and include the currently held keys on that backend; the 26 event path is unchanged.
        let flags = backend == .accessibility ? event.modifierFlags.union(NSEvent.modifierFlags) : event.modifierFlags
        let isContextClick = event.type == .rightMouseUp
            || (event.type == .leftMouseUp && flags.contains(.control))
        FrostLog.sections.debug("Frost icon action (event type \(event.type.rawValue, privacy: .public))")
        handleIconClick(context: isContextClick, option: flags.contains(.option),
                        screen: clickedScreen(for: event))
    }

    /// The display a click on the Frost icon happened on. After a click on another display's replica, the system can
    /// deliver the click to the button before it moves the real window to that display (seen in the VM during a
    /// Frost Bar live refresh round), so the window's screen may still be the previous one; the pointer is where the
    /// user clicked. Non-mouse actions (e.g. VoiceOver) use the window's screen.
    private func clickedScreen(for event: NSEvent) -> NSScreen? {
        let windowScreen = iconItem?.button?.window?.screen
        guard [.leftMouseUp, .rightMouseUp, .leftMouseDown, .rightMouseDown].contains(event.type) else {
            return windowScreen
        }
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? windowScreen
    }

    /// A click on the Frost icon that the freeze frame of a background capture took (the icon had shifted under it, see
    /// `FrostBarController+ObscuredCapture`): handled now, once the menu bar is back as it was, as if it had reached
    /// the icon.
    func replayIconClick(context: Bool, option: Bool, screen: NSScreen?) {
        FrostLog.sections.notice("handling a Frost icon click taken by a background capture's freeze frame")
        handleIconClick(context: context, option: option, screen: screen)
    }

    /// Right-click / Control-click -> menu; click -> Frost Bar (per the effective display mode of `screen`, the display
    /// clicked on) or toggle collapsed <-> expanded; with ⌥ -> expandedAll.
    private func handleIconClick(context: Bool, option: Bool, screen: NSScreen?) {
        if context {
            showMenu()
            return
        }
        guard !isEditing else { return }
        // The mode depends on Accessibility: read it now, a grant made in System Settings while Frost wasn't active
        // may not have reached the cached value yet.
        permissions.refresh()
        let mode = preferences.effectiveDisplayMode(for: screen, capabilities: permissions.capabilities)
        if mode == .frostBar {
            model?.toggleFrostBar(option)
            return
        }
        // During a temporary expansion (the Frost Bar's live refresh, possibly on another display) the real state is
        // the temporary one; judge the click against the state the user sees and let `restore` apply it.
        if temporaryExpansion != nil {
            temporaryExpansion?.iconClicked(option: option)
            FrostLog.sections.notice("Frost icon clicked during a temporary expansion; applied when it ends")
            return
        }
        setState(state.afterIconClick(option: option))
    }

    private func showMenu() {
        guard let iconItem, let button = iconItem.button else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        permissions.refresh()
        if !isManagingMenuBar {
            // Unsupported macOS: say so first (one disabled item, the explanation as its subtitle). Permissions don't
            // help here, so no Grant Access.
            let notice = NSMenuItem(title: RunningOS.title, action: nil, keyEquivalent: "")
            notice.subtitle = RunningOS.detail
            notice.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            notice.isEnabled = false
            menu.addItem(notice)
            menu.addItem(.separator())
        } else if !permissions.canManageItems {
            // A reminder for users who chose "Not Now": the Frost Bar and the layout editor need Accessibility, and
            // until then hidden icons expand in the menu bar.
            let grant = NSMenuItem(
                title: String(localized: "Grant Access…", comment: "Frost icon context menu item shown without Accessibility"),
                action: #selector(grantAccessibility), keyEquivalent: "")
            grant.target = self
            grant.image = NSImage(systemSymbolName: "accessibility", accessibilityDescription: nil)
            grant.toolTip = String(localized: "The Frost Bar needs the Accessibility permission.")
            menu.addItem(grant)
            menu.addItem(.separator())
        }
        let settings = NSMenuItem(
            title: String(localized: "Settings…", comment: "Frost icon context menu item"),
            action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        // Every item gets its own symbol so the titles line up (the system adds one automatically only to some
        // standard items, and only for some languages).
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)
        let update: NSMenuItem
        if model?.updates.pendingUpdateVersion != nil {
            // A scheduled check found an update (gentle reminder): this brings its window to the front.
            update = NSMenuItem(
                title: String(localized: "Update Available…",
                              comment: "Frost icon context menu item shown when an update is waiting to be installed"),
                action: #selector(checkForUpdates), keyEquivalent: "")
            update.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        } else {
            update = NSMenuItem(
                title: String(localized: "Check for Updates…", comment: "Frost icon context menu item"),
                action: #selector(checkForUpdates), keyEquivalent: "")
            update.isEnabled = model?.updates.canCheckForUpdates ?? false
            update.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        }
        update.target = self
        menu.addItem(update)
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: String(localized: "Quit Frost", comment: "Frost icon context menu item"),
            action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quit)
        iconItem.menu = menu
        button.performClick(nil)
        iconItem.menu = nil
    }

    /// While Frost posts a move's ⌘-drag (its mouse-down physically lands on the Frost icon, see `ItemMover`), the
    /// icon must not show a pressed highlight: the user clicked a tile in the Frost Bar, not the snowflake. Restored a
    /// little after the move, once the routed mouse-up has been handled too. The user's own clicks on the icon still
    /// work meanwhile (only the highlight is off).
    func suppressIconHighlight(_ suppressed: Bool) {
        guard let button = iconItem?.button, let cell = button.cell as? NSButtonCell else { return }
        highlightRestoreTask?.cancel()
        highlightRestoreTask = nil
        if suppressed {
            if savedHighlightsBy == nil { savedHighlightsBy = cell.highlightsBy }
            cell.highlightsBy = []
            button.highlight(false)
            return
        }
        highlightRestoreTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.highlightRestoreDelay) } catch { return }
            guard let self, let saved = self.savedHighlightsBy else { return }
            self.savedHighlightsBy = nil
            self.highlightRestoreTask = nil
            cell.highlightsBy = saved
        }
    }

    @ObservationIgnored private var savedHighlightsBy: NSCell.StyleMask?
    @ObservationIgnored private var highlightRestoreTask: Task<Void, Never>?
    private static let highlightRestoreDelay: Duration = .milliseconds(300)

    @objc private func openSettings() { model?.openSettings() }

    @objc private func grantAccessibility() { permissions.requestAccessibility() }

    /// "Check for Updates…" brings Settings → About forward first, so its "Last checked" row is in view next to
    /// Sparkle's window when the check ends; "Update Available…" (the reminder) just brings the update window back.
    @objc private func checkForUpdates() {
        guard let model else { return }
        guard model.updates.pendingUpdateVersion == nil else {
            model.updates.checkForUpdates()
            return
        }
        model.openSettings(tab: .about)
        // On the next turn of the run loop, once the Settings window is ordered front: Sparkle's window opens above it.
        Task { @MainActor in model.updates.checkForUpdates() }
    }

    // MARK: - Snowflake replicas on other displays

    /// A display was connected, disconnected or rearranged: the scanned menu bar (`scanner.menuBarDisplay`) and the
    /// replica frames (`scanner.replicaIconFrames`, used to recognize clicks on a snowflake replica) must be fresh, or
    /// the first click on a newly connected display's snowflake is missed. The new display's menu bar windows show up
    /// shortly after the notification, so rescan now and again a little later, then read ownership once more.
    private func rescanAfterDisplayChange() {
        updateDividerWidthsForDisplay()
        scanner.rescan()
        displayRescanTask?.cancel()
        displayRescanTask = Task { [weak self] in
            for delay: Duration in [.milliseconds(300), .seconds(1)] {
                do { try await Task.sleep(for: delay) } catch { return }
                self?.scanner.rescan()
            }
            self?.scanner.scheduleRescan(after: .zero, refreshOwnership: true)
        }
        FrostLog.sections.notice("display configuration changed (\(NSScreen.screens.count) display(s)); rescanning")
    }

    /// With more than one display, monitors the mouse (global: events on a replica belong to another window; local:
    /// events the system redelivers to the Frost icon); removes the monitors with a single display.
    private func updateReplicaClickMonitors() {
        let needed = NSScreen.screens.count > 1
        if needed, replicaClickMonitors.isEmpty {
            replicaClickMonitors.add(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp],
                                     global: { [weak self] event in self?.replicaMouseEvent(event, isLocal: false) },
                                     local: { [weak self] event in self?.replicaMouseEvent(event, isLocal: true) })
        } else if !needed, !replicaClickMonitors.isEmpty {
            replicaClickMonitors.removeAll()
            replicaClickTask?.cancel()
            replicaClickTask = nil
            replicaClicks = ReplicaClickDetector()
        }
    }

    private func replicaMouseEvent(_ event: NSEvent, isLocal: Bool) {
        let button: ReplicaClickDetector.Button
        switch event.type {
        case .leftMouseDown, .leftMouseUp: button = .left
        case .rightMouseDown, .rightMouseUp: button = .right
        default: return
        }
        let isDown = event.type == .leftMouseDown || event.type == .rightMouseDown
        if isDown {
            if isLocal {
                guard event.window === iconWindow, !Self.dropRedeliveredReplicaClicks else { return }
                replicaClicks.deliveredMouseDown(time: event.timestamp)
                return
            }
            // Global monitor events have no window, so `locationInWindow` is in screen coordinates (AppKit, bottom-left origin).
            let point = ScreenCoordinates.cgPoint(fromAppKit: event.locationInWindow)
            let control = event.modifierFlags.contains(.control), option = event.modifierFlags.contains(.option)
            var hit = replicaClicks.globalMouseDown(at: point, time: event.timestamp, button: button, control: control,
                                                    option: option, replicaIcons: scanner.replicaIconFrames)
            // A display connected moments ago: its replica may have appeared after the last rescan
            // (`rescanAfterDisplayChange`). A click in another display's menu bar that misses every known replica is
            // rare and cheap to double-check.
            let pointer = NSEvent.mouseLocation
            if !hit, isInMenuBar(pointer),
               let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }),
               (screen.displayID ?? 0) != iconDisplayID {
                scanner.rescan()
                hit = replicaClicks.globalMouseDown(at: point, time: event.timestamp, button: button, control: control,
                                                    option: option, replicaIcons: scanner.replicaIconFrames)
            }
            if hit {
                let active = iconDisplayID ?? 0
                FrostLog.sections.notice("mouse down on a Frost icon replica at (\(point.x), \(point.y)); active display \(active)")
            }
            return
        }
        guard replicaClicks.hasPendingClick else { return }
        replicaClicks.mouseUp(button: button, time: event.timestamp)
        replicaClickTask?.cancel()
        replicaClickTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(ReplicaClickDetector.grace) + .milliseconds(20)) } catch { return }
            await self?.fireReplicaClickIfDue()
        }
    }

    /// The click didn't reach the button within `grace` of mouse-up: wait (up to 0.5 s) for the real window to move
    /// to the clicked display, then handle it as a click.
    private func fireReplicaClickIfDue() async {
        guard let click = replicaClicks.due(now: ProcessInfo.processInfo.systemUptime) else { return }
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(500)
        while iconWindow?.screen?.displayID != click.displayID, clock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
        }
        let current = iconWindow?.screen?.displayID ?? 0
        FrostLog.sections.notice(
            "click on the Frost icon replica on display \(click.displayID) did not reach the button; handling it (icon on display \(current))")
        let screen = NSScreen.screens.first { ($0.displayID ?? 0) == click.displayID } ?? iconWindow?.screen
        handleIconClick(context: click.isContextClick, option: click.option, screen: screen)
    }

    @objc private func quit() { NSApp.terminate(nil) }

}

/// The H / AH separator status items.
@MainActor
private final class SeparatorItem {
    enum Mode: Equatable {
        /// `length = 10_000`: pushes everything to the left off screen.
        case pushOut
        /// `length = 0`, narrowed to 1 pt where possible (the system leaves a 16 pt gap by default).
        case zero
        /// Thin vertical line in the layout editor (`length = 8`).
        case line
    }

    static let pushOutLength: CGFloat = 10_000
    static let lineLength: CGFloat = 8
    /// What a divider takes when its section is revealed (macOS 27, `BoundedDivider.revealWidth`).
    static let revealLength: CGFloat = 0

    let item: NSStatusItem
    let companion: SeparatorItem?
    let companionName: String?
    private let backend: MenuBarBackend
    var mode: Mode? {
        didSet {
            companion?.mode = mode
            if mode != oldValue || mode == .zero { apply() }
        }
    }

    /// How wide this divider is when it pushes its section out: `pushOutLength` on macOS 26, the bounded width on
    /// macOS 27. Set by the owner before the mode is applied; a width change on an already collapsed divider is
    /// applied too (the display can change while the sections are collapsed).
    var collapseWidth: CGFloat = SeparatorItem.pushOutLength {
        didSet {
            companion?.collapseWidth = collapseWidth
            if mode == .pushOut, collapseWidth != oldValue { apply() }
        }
    }

    /// Ice's trick: the window's content view has the constraint
    /// `NSStatusBarContentView.width == button.superview.width + 16`,
    /// which leaves a 16 pt gap even at length 0. Deactivate it and set the window content width to 1. If it can't
    /// be found, keep the 16 pt.
    private var gapConstraint: NSLayoutConstraint?
    private var resizeObserver: NSObjectProtocol?
    private var reapplyTimes: [ContinuousClock.Instant] = []
    private var gaveUpNarrowing = false

    init(autosaveName: String, backend: MenuBarBackend = .windowList, paired: Bool = true) {
        self.backend = backend
        companionName = backend == .accessibility && paired ? autosaveName + ".Pair" : nil
        companion = companionName.map { SeparatorItem(autosaveName: $0, backend: backend, paired: false) }
        collapseWidth = backend == .accessibility ? Self.lineLength : Self.pushOutLength
        item = NSStatusBar.system.statusItem(
            withLength: backend == .accessibility ? Self.lineLength : Self.pushOutLength)
        item.autosaveName = autosaveName
        item.isVisible = true
        if let button = item.button {
            button.setAccessibilityLabel(
                String(localized: "Frost Separator", comment: "Accessibility label of Frost's section separator status items"))
            (button.cell as? NSButtonCell)?.highlightsBy = []
        }
        if let window = item.button?.window {
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowDidResize() }
            }
        }
    }

    /// The button window's frame in CG coordinates.
    var cgFrame: CGRect? {
        item.button?.window.map { ScreenCoordinates.cgRect(fromAppKit: $0.frame) }
    }

    private func apply() {
        guard let mode, let button = item.button else { return }
        switch mode {
        case .pushOut:
            restoreGap()
            button.image = nil
            button.isEnabled = false
            item.length = collapseWidth
        case .line:
            restoreGap()
            button.image = Self.lineImage
            // Keep enabled, or the line is drawn in the faded disabled color; with no action, clicks do nothing.
            button.isEnabled = true
            item.length = Self.lineLength
        case .zero:
            button.image = nil
            button.isEnabled = false
            if backend == .accessibility {
                // The 26 constraint trick makes AppKit and AX disagree about the slot on 27. Keep the
                // measured narrow width so reacquisition and own-divider placement address the same item.
                restoreGap()
                item.length = BoundedDivider.editingWidth
                return
            }
            item.length = 0
            narrow()
        }
    }

    private func narrow() {
        guard !gaveUpNarrowing, let button = item.button, let window = button.window else { return }
        if gapConstraint == nil {
            gapConstraint = window.contentView?.constraintsAffectingLayout(for: .horizontal)
                .first { $0.secondItem === button.superview }
        }
        guard let gapConstraint else { return }
        gapConstraint.isActive = false
        var size = window.frame.size
        size.width = 1
        window.setContentSize(size)
    }

    private func restoreGap() {
        guard let gapConstraint, !gapConstraint.isActive else { return }
        gapConstraint.isActive = true
    }

    /// The system may restore the window to 16 pt when it re-lays out the menu bar: narrow it again in `.zero`.
    /// If the system reverts it more than 10 times within 1 second, give up narrowing (keep 16 pt) to avoid fighting it.
    private func windowDidResize() {
        guard backend == .windowList, mode == .zero, !gaveUpNarrowing,
              let width = item.button?.window?.frame.width, width > 1 else { return }
        let now = ContinuousClock.now
        reapplyTimes = reapplyTimes.filter { now - $0 < .seconds(1) } + [now]
        if reapplyTimes.count > 10 {
            gaveUpNarrowing = true
            restoreGap()
            return
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.mode == .zero else { return }
                self.narrow()
            }
        }
    }

    /// 1 pt x 14 pt rounded vertical line whose color follows the appearance (`secondaryLabelColor`).
    static let lineImage: NSImage = {
        let image = NSImage(size: NSSize(width: 1, height: 14), flipped: false) { rect in
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 0.5, yRadius: 0.5).fill()
            return true
        }
        image.isTemplate = false
        return image
    }()
}
