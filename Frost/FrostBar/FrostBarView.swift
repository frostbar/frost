import FrostCore
import SwiftUI

// MARK: - State

/// Everything the Frost Bar draws from (a value type: the view does not depend on services directly, so it can be
/// rendered offscreen with fake data).
struct FrostBarState {
    enum Phase: Equatable {
        case loading
        /// Accessibility isn't granted (or was revoked while the panel was open).
        case needsPermission
        /// `scanner.status == .noWindows` or Frost's separator is missing: say so explicitly instead of silently
        /// showing an empty panel.
        case unreadable
        /// Scanning works, but the sections to show really have no icons.
        case empty
        case ready
    }

    var phase: Phase
    /// The Always Hidden section (left to right, below the Hidden section) when opened with Option, empty otherwise.
    var alwaysHidden: [MenuBarItem]
    /// The Hidden section (left to right).
    var hidden: [MenuBarItem]
    var images: [CGWindowID: CGImage]
    /// Size of each capture in points: captures and tile widths follow it rather than the item's current frame (see
    /// `ItemImageCapturer.sizes`).
    var imageSizes: [CGWindowID: CGSize] = [:]
    /// Width each tile is laid out with, before the standard minimum and the grid cap: the widest width seen this
    /// session (`TileWidthMemory`), so items whose width keeps changing don't make the panel resize repeatedly. Items
    /// without an entry use their capture width (or frame width).
    var contentWidths: [CGWindowID: CGFloat] = [:]
    /// VoiceOver label of each tile: app name and the item's own description (`MenuBarItem.accessibilityName`).
    var accessibilityLabels: [CGWindowID: String] = [:]
    /// Short labels for tiles without a capture (`ItemFallbackAppearance.labels`).
    var fallbackLabels: [CGWindowID: String] = [:]
    /// Whether each capture is a monochrome glyph or a colored icon (see `GlyphStyle`).
    var styles: [CGWindowID: GlyphStyle]
    /// Template images of monochrome glyphs: tinted with the foreground color so they follow the glass's actual
    /// brightness (the glass adapts to the content behind it, so white / black glyphs captured with the menu bar's
    /// appearance could land on glass of the same color).
    var templates: [CGWindowID: CGImage]
    var names: [CGWindowID: String]
    /// App icons for items without a capture.
    var appIcons: [CGWindowID: NSImage]
    /// Maximum width / height of the panel's visible content (usable screen area minus margins); taller content
    /// scrolls vertically.
    var maxWidth: CGFloat
    var maxHeight: CGFloat
    /// Target state of the show / hide animation.
    var isPresented: Bool
    var isRefreshing: Bool
    /// The Always Hidden section is fading out (the panel shrinks once it's gone).
    var isAlwaysHiddenFading = false
    /// Accessibility is granted but Screen Recording isn't, and the user hasn't closed the hint: suggest granting it
    /// for real icon images.
    var showsScreenRecordingHint = false
    /// Screen Recording was requested and takes effect after a relaunch: the hint offers Relaunch instead.
    var screenRecordingNeedsRelaunch = false

    var items: [MenuBarItem] { hidden + alwaysHidden }
}

/// Actions emitted by the Frost Bar.
struct FrostBarActions {
    /// A tile was clicked: forward `click` to its item.
    var activate: @MainActor (_ item: MenuBarItem, _ click: ForwardedClick) -> Void
    /// The pointer entered a tile (nil: left every tile). Right clicks on the panel go to the hovered tile
    /// (`FrostBarPanel.onSecondaryClick`): SwiftUI buttons don't report them.
    var hover: @MainActor (_ windowID: CGWindowID?) -> Void = { _ in }
    var refresh: @MainActor () -> Void
    var grantAccessibility: @MainActor () -> Void
    var grantScreenRecording: @MainActor () -> Void
    /// Opens System Settings' Screen Recording pane (shown next to Relaunch while a relaunch is pending).
    var openScreenRecordingSettings: @MainActor () -> Void = {}
    var relaunch: @MainActor () -> Void
    var openSettings: @MainActor () -> Void
    /// The user closed the Screen Recording hint.
    var dismissScreenRecordingHint: @MainActor () -> Void = {}
}

/// Size constants and panel size calculations. All sizes are determined here (independent of the text's ideal
/// width), so a name changing on hover never resizes the panel.
enum FrostBarMetrics {
    /// Transparent margin around the window (the panel shadow is drawn in it). It must fit the glass's own shadow and
    /// the `.shadow` below, or the shadow is clipped at the window edge and shows a hard-edged rectangle over white
    /// windows.
    static let inset: CGFloat = 40
    /// The top margin only leaves the gap to the menu bar: the window's top edge sits exactly at the menu bar's bottom
    /// edge so no shadow is drawn into the menu bar (on real GPUs that is a visible dark band that also flickers when
    /// the freeze frame is added / removed). Clipping the top shadow is therefore intentional.
    static let topInset: CGFloat = PanelPlacement.defaultGap
    /// Panel corner radius (matches macOS 26 menus / popovers).
    static let cornerRadius: CGFloat = 20
    /// Distance from the grid to the panel edge; tile corner radius = panel corner radius - padding (concentric).
    static let padding: CGFloat = 8
    static var tileCornerRadius: CGFloat { cornerRadius - padding }
    static let tileHeight: CGFloat = 36
    /// Width of a standard icon tile; wide text items use their capture width.
    static let standardTileWidth: CGFloat = 40
    static let tileSpacing: CGFloat = 4
    static let lineSpacing: CGFloat = 4
    /// Maximum standard tiles per row (sets the grid's maximum width); the panel is at least `minColumns` tiles wide.
    static let columns = 5
    static let minColumns = 4
    /// Height of the Always Hidden divider and title.
    static let sectionHeaderHeight: CGFloat = 28
    /// Height of the footer (the hovered app's name).
    static let footerHeight: CGFloat = 30
    /// Height of the Screen Recording hint row above the footer (when shown).
    static let hintHeight: CGFloat = 40
    /// While a relaunch is pending the hint stacks its two actions under the text (they don't fit beside it in a
    /// panel this narrow), so it needs a second line.
    static let relaunchHintHeight: CGFloat = 62
    /// Height of the hint row in this state (`hintHeight` when it is a single line).
    static func hintHeight(_ state: FrostBarState) -> CGFloat {
        state.screenRecordingNeedsRelaunch ? relaunchHintHeight : hintHeight
    }
    /// Content width of non-icon states (empty, no permissions, ...).
    static let statusWidth: CGFloat = 232
    /// Minimum content width while the relaunch hint is shown. At the narrowest grid the hint has room for neither
    /// its sentence (it would truncate mid-sentence) nor its two actions side by side (they would wrap); `statusWidth`
    /// is the width the panel already takes for its other text-only shapes.
    static let relaunchHintWidth: CGFloat = statusWidth
    /// Showing / hiding the Always Hidden section (⌥-click while open): a short fade and height change. The window
    /// grows at once and shrinks after it (see `FrostBarController.reposition`).
    static let sectionAnimation: Animation = .snappy(duration: 0.24)

    static func rowWidth(columns: Int) -> CGFloat {
        CGFloat(columns) * standardTileWidth + CGFloat(columns - 1) * tileSpacing
    }

    /// Maximum grid width: 5 standard tiles, never wider than the screen.
    static func gridCap(_ state: FrostBarState) -> CGFloat {
        max(standardTileWidth, min(rowWidth(columns: columns), state.maxWidth - 2 * padding))
    }

    /// Tile widths: the capture width, or for items without a capture yet the width the capture will have (the
    /// item's frame), so the panel doesn't resize when a live refresh delivers it (see `TileWidth`).
    static func tileWidths(_ items: [MenuBarItem], _ state: FrostBarState) -> [CGFloat] {
        let cap = gridCap(state)
        return items.map { item in
            let captureWidth = state.contentWidths[item.windowID]
                ?? (state.images[item.windowID] == nil ? nil : state.imageSizes[item.windowID]?.width)
            return TileWidth.width(captureWidth: captureWidth, frameWidth: item.frame.width, standard: standardTileWidth,
                                   cap: cap)
        }
    }

    static func gridSize(_ items: [MenuBarItem], _ state: FrostBarState) -> CGSize {
        FlowRows.size(tileWidths(items, state), maxWidth: gridCap(state), spacing: tileSpacing,
                      rowHeight: tileHeight, lineSpacing: lineSpacing)
    }

    /// Width of the grid area (panel content): the widest grid, at least `minColumns` tiles wide (room for the footer),
    /// and while a relaunch is pending at least `relaunchHintWidth` (the hint below the grid needs the room).
    static func contentWidth(_ state: FrostBarState) -> CGFloat {
        let widest = max(gridSize(state.hidden, state).width, gridSize(state.alwaysHidden, state).width)
        let grid = min(max(widest, rowWidth(columns: minColumns)), gridCap(state))
        guard state.showsScreenRecordingHint, state.screenRecordingNeedsRelaunch else { return grid }
        return max(grid, relaunchHintWidth)
    }

    /// Full height of the grids (excluding the footer).
    static func gridsHeight(_ state: FrostBarState) -> CGFloat {
        var height = 2 * padding
        if !state.hidden.isEmpty { height += gridSize(state.hidden, state).height }
        if !state.alwaysHidden.isEmpty {
            height += sectionHeaderHeight + gridSize(state.alwaysHidden, state).height
        }
        return height
    }

    /// Visible height of the grids: scrolls when taller than the usable screen height.
    static func gridsViewportHeight(_ state: FrostBarState) -> CGFloat {
        let chrome = footerHeight + (state.showsScreenRecordingHint ? hintHeight(state) : 0)
        return min(gridsHeight(state), max(tileHeight + 2 * padding, state.maxHeight - chrome))
    }
}

// MARK: - View

/// Pure presentation: depends only on `FrostBarState` and callbacks.
struct FrostBarContent: View {
    let state: FrostBarState
    let actions: FrostBarActions

    @State private var hovered: CGWindowID?

    init(state: FrostBarState, actions: FrostBarActions, initialHover: CGWindowID? = nil) {
        self.state = state
        self.actions = actions
        _hovered = State(initialValue: initialHover)
    }

    var body: some View {
        panel
            .padding(EdgeInsets(top: FrostBarMetrics.topInset, leading: FrostBarMetrics.inset,
                                 bottom: FrostBarMetrics.inset, trailing: FrostBarMetrics.inset))
            // Unfolds downward from the Frost icon (the panel's top-right corner).
            .offset(y: state.isPresented ? 0 : -4)
            .opacity(state.isPresented ? 1 : 0)
            .onChange(of: state.isPresented) { _, presented in
                if !presented { hovered = nil }
            }
            .onChange(of: hovered) { _, id in actions.hover(id) }
    }

    // MARK: Panel

    private var panel: some View {
        let shape = RoundedRectangle(cornerRadius: FrostBarMetrics.cornerRadius, style: .continuous)
        return Group {
            switch state.phase {
            case .ready:
                grid
            case .empty:
                StatusMessage(symbol: "snowflake", tint: .cyan, title: "No Hidden Icons",
                              detail: "Drag icons into the Hidden section in the layout editor.") {
                    PillButton(title: "Arrange Icons…", symbol: "square.grid.3x1.below.line.grid.1x2",
                               action: actions.openSettings)
                }
            case .unreadable:
                StatusMessage(symbol: "exclamationmark", tint: .orange, title: "Can’t Read Menu Bar Icons",
                              detail: "The menu bar icons can’t be read right now. Refresh to try again.") {
                    PillButton(title: "Refresh", symbol: "arrow.clockwise", isSpinning: state.isRefreshing,
                               action: actions.refresh)
                }
            case .needsPermission:
                StatusMessage(symbol: "lock.fill", tint: .orange, title: "Accessibility Required",
                              detail: "The Frost Bar needs the Accessibility permission.") {
                    PillButton(title: "Grant Access", symbol: "arrow.up.forward", action: actions.grantAccessibility)
                }
            case .loading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading the menu bar…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(width: FrostBarMetrics.statusWidth, height: 64)
            }
        }
        .frostBarGlass(in: shape)
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .animation(.snappy, value: state.phase)
    }

    // MARK: Icon grid

    private var grid: some View {
        let width = FrostBarMetrics.contentWidth(state)
        let viewport = FrostBarMetrics.gridsViewportHeight(state)
        let scrolls = viewport < FrostBarMetrics.gridsHeight(state)
        return VStack(spacing: 0) {
            Group {
                if scrolls {
                    ScrollView(.vertical) { sections(width: width) }
                        .scrollIndicators(.automatic)
                        // Fixed width: a legacy scroller must not widen the panel (it would misalign with the footer).
                        .frame(width: width + 2 * FrostBarMetrics.padding, height: viewport)
                } else {
                    sections(width: width)
                }
            }
            if state.showsScreenRecordingHint {
                ScreenRecordingHint(needsRelaunch: state.screenRecordingNeedsRelaunch, grant: actions.grantScreenRecording,
                                    openSettings: actions.openScreenRecordingSettings, relaunch: actions.relaunch,
                                    dismiss: actions.dismissScreenRecordingHint)
                    .frame(width: width + 2 * FrostBarMetrics.padding, height: FrostBarMetrics.hintHeight(state))
                    .transition(.opacity)
            }
            footer
                .frame(width: width + 2 * FrostBarMetrics.padding)
        }
    }

    /// The Hidden section grid; with Option, followed by the Always Hidden divider and its grid.
    private func sections(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !state.hidden.isEmpty {
                tiles(state.hidden)
            }
            if !state.alwaysHidden.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "Always Hidden", showsDivider: !state.hidden.isEmpty)
                        .frame(height: FrostBarMetrics.sectionHeaderHeight)
                    tiles(state.alwaysHidden)
                }
                .opacity(state.isAlwaysHiddenFading ? 0 : 1)
                // The footer moves through the section's area while the panel's height changes: the section fades in
                // once the footer has mostly passed, and fades out before the panel shrinks (`isAlwaysHiddenFading`),
                // so they never overlap.
                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.14).delay(0.1)),
                                        removal: .identity))
            }
        }
        .frame(width: width, alignment: .leading)
        .padding(FrostBarMetrics.padding)
    }

    private func tiles(_ items: [MenuBarItem]) -> some View {
        let widths = FrostBarMetrics.tileWidths(items, state)
        return FlowLayout(maxWidth: FrostBarMetrics.gridCap(state), spacing: FrostBarMetrics.tileSpacing,
                          lineSpacing: FrostBarMetrics.lineSpacing) {
            ForEach(Array(zip(items, widths)), id: \.0.id) { item, width in
                tile(item, width: width)
            }
        }
    }

    private func tile(_ item: MenuBarItem, width: CGFloat) -> some View {
        let image = state.images[item.windowID]
        // Colored icons are shown as is, with a plate only when they have large pure white / black areas; monochrome
        // glyphs are tinted via their template image.
        var plate: GlyphTone?
        if image != nil, case .colored(let needed) = state.styles[item.windowID] { plate = needed }
        return FrostBarTile(item: item, image: image, imageSize: state.imageSizes[item.windowID],
                            template: state.templates[item.windowID],
                            appIcon: state.appIcons[item.windowID], label: state.fallbackLabels[item.windowID],
                            plate: plate?.outlinePlateColor, width: width,
                            accessibilityName: state.accessibilityLabels[item.windowID]
                                ?? state.names[item.windowID] ?? item.windowTitle,
                            isHovered: hovered == item.windowID,
                            action: { actions.activate(item, Self.forwardedClick(for: NSApp.currentEvent)) },
                            showMenu: { actions.activate(item, .secondary) })
            .onHover { inside in
                if inside {
                    hovered = item.windowID
                } else if hovered == item.windowID {
                    hovered = nil
                }
            }
    }

    /// The click to forward for a tile's button action: the event's own mouse button (on a real Mac a right or
    /// two-finger click can trigger the SwiftUI button action directly, so the button must come from the event, not be
    /// assumed), ⌥ adds Option, ⌃ makes it a right click. Keyboard / VoiceOver presses forward a plain click.
    private static func forwardedClick(for event: NSEvent?) -> ForwardedClick {
        let flags = event?.modifierFlags ?? []
        let button: ForwardedClick.Button = switch event?.type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged: .right
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged: .other
        default: .left
        }
        return ForwardedClick.kind(button: button, control: flags.contains(.control), option: flags.contains(.option))
            ?? .primary
    }

    // MARK: Footer

    /// Bottom row of the panel: the hovered icon's app name, otherwise the icon count. Fixed height and width, so
    /// hovering never resizes the panel.
    private var footer: some View {
        let name = hovered.flatMap { state.names[$0] }
        return VStack(spacing: 0) {
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 0.5)
                .padding(.horizontal, FrostBarMetrics.padding + 4)
            ZStack(alignment: .leading) {
                if let name {
                    Text(name)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .transition(.opacity)
                        .id(name)
                } else {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        // The count changes with the Always Hidden section while the footer moves: swap the text
                        // as it moves (a cross-fade shows the new text at the end position early).
                        .contentTransition(.identity)
                        .transition(.opacity)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, FrostBarMetrics.padding + 6)
        }
        .frame(height: FrostBarMetrics.footerHeight)
        .animation(.easeOut(duration: 0.12), value: name)
        .allowsHitTesting(false)
    }

    private var summary: String {
        let hidden = state.hidden.count, always = state.alwaysHidden.count
        if always == 0 { return String(localized: "\(hidden) hidden icons") }
        if hidden == 0 { return String(localized: "\(always) always-hidden icons") }
        return String(localized: "\(hidden) hidden · \(always) always hidden")
    }
}

private extension GlyphTone {
    /// Outline plate for colored icons: only needs to separate pure white / black outlines from glass of the same
    /// color, so it is fainter than the layout editor's glyph plate.
    var outlinePlateColor: Color {
        switch self {
        case .light: Color.black.opacity(0.3)
        case .dark: Color.white.opacity(0.45)
        }
    }
}

// MARK: - Glass

private extension View {
    /// The panel's glass. When checking layout via offscreen rendering (compile condition `FROST_OFFSCREEN_RENDER`),
    /// `cacheDisplay` cannot draw glass, or even the images inside it, so an approximate translucent fill is used
    /// instead; the app itself always uses real glass.
    @ViewBuilder func frostBarGlass(in shape: some Shape) -> some View {
        #if FROST_OFFSCREEN_RENDER
        background {
            shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.86))
                .overlay(shape.stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        }
        #else
        glassEffect(.regular, in: shape)
        #endif
    }
}

// MARK: - Flow layout

/// A grid laid out in order that wraps when a row is full (rows left-aligned). Wrapping follows `FlowRows`, matching
/// the size calculations in `FrostBarMetrics`.
struct FlowLayout: Layout {
    var maxWidth: CGFloat
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return FlowRows.size(sizes.map(\.width), maxWidth: limit(proposal), spacing: spacing,
                             rowHeight: sizes.map(\.height).max() ?? 0, lineSpacing: lineSpacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let widths = sizes.map(\.width)
        let rowHeight = sizes.map(\.height).max() ?? 0
        var y = bounds.minY
        for row in FlowRows.pack(widths, maxWidth: limit(proposal), spacing: spacing) {
            var x = bounds.minX
            for index in row {
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: widths[index], height: rowHeight))
                x += widths[index] + spacing
            }
            y += rowHeight + lineSpacing
        }
    }

    private func limit(_ proposal: ProposedViewSize) -> CGFloat {
        min(proposal.width ?? maxWidth, maxWidth)
    }
}

// MARK: - Components

/// One icon: shows the capture at its original size, with a rounded highlight on hover (similar to a pressed menu
/// bar item).
private struct FrostBarTile: View {
    let item: MenuBarItem
    let image: CGImage?
    let imageSize: CGSize?
    let template: CGImage?
    let appIcon: NSImage?
    /// Short label for a tile without a capture (`ItemFallbackAppearance`).
    let label: String?
    /// Plate color for colored icons with large pure white / black areas (monochrome glyphs are tinted via their
    /// template image and need no plate).
    let plate: Color?
    let width: CGFloat
    let accessibilityName: String
    let isHovered: Bool
    let action: () -> Void
    /// Forwards a right click (the item's secondary menu); offered to assistive technologies as "show menu".
    let showMenu: () -> Void

    var body: some View {
        Button(action: action) {
            ItemGlyph(item: item, image: image, template: template, appIcon: appIcon, appIconSize: 20,
                      imageSize: imageSize, label: image == nil ? label : nil)
                .frame(width: width, height: FrostBarMetrics.tileHeight)
                .clipped()
        }
        .buttonStyle(TileButtonStyle(isHovered: isHovered, plate: plate))
        .accessibilityLabel(accessibilityName)
        .accessibilityHint("Opens this icon’s menu")
        .accessibilityAction(.showMenu, showMenu)
    }
}

private struct TileButtonStyle: ButtonStyle {
    let isHovered: Bool
    let plate: Color?

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: FrostBarMetrics.tileCornerRadius, style: .continuous)
        configuration.label
            .background {
                if let plate {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(plate)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 6)
                }
            }
            .background {
                shape.fill(Color.primary.opacity(configuration.isPressed ? 0.18 : isHovered ? 0.1 : 0))
            }
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.snappy(duration: 0.16), value: isHovered)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

/// Title of the Always Hidden section: a thin divider and small caption text (similar to menu section headers).
private struct SectionHeader: View {
    let title: LocalizedStringKey
    let showsDivider: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsDivider {
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(height: 0.5)
                    .padding(.horizontal, 4)
                    .padding(.top, 5)
            }
            Spacer(minLength: 0)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
                .padding(.bottom, 4)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// Screen Recording isn't granted: tiles show app icons. A subtle row offering real images (opens onboarding), with a
/// close button that hides it for good.
private struct ScreenRecordingHint: View {
    let needsRelaunch: Bool
    let grant: () -> Void
    let openSettings: () -> Void
    let relaunch: () -> Void
    let dismiss: () -> Void
    @State private var isHovered = false

    var body: some View {
        Group {
            if needsRelaunch {
                // The two actions don't fit next to the text in a panel this narrow; they get their own line, with
                // Relaunch (the step that finishes the grant) last.
                VStack(spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.orange)
                        Text("Turn on Frost in System Settings, then relaunch.")
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        dismissButton
                    }
                    HStack(spacing: 12) {
                        Spacer(minLength: 0)
                        Button("Open System Settings", action: openSettings)
                        Button("Relaunch", action: relaunch)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    // The panel's secondary style would otherwise make them look like plain text.
                    .foregroundStyle(.tint)
                }
            } else {
                HStack(spacing: 6) {
                    Button(action: grant) {
                        Label {
                            Text("Grant Screen Recording to see real icons")
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "rectangle.dashed.badge.record")
                        }
                        .font(.caption)
                        .foregroundStyle(isHovered ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .onHover { isHovered = $0 }
                    .accessibilityHint("Opens System Settings")
                    dismissButton
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, FrostBarMetrics.padding + 6)
        .animation(.snappy(duration: 0.16), value: isHovered)
    }

    private var dismissButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Color.primary.opacity(0.08), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Don’t show again")
    }
}

/// A status in the panel: colored round badge, title, detail and action.
private struct StatusMessage<Action: View>: View {
    let symbol: String
    let tint: Color
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 0) {
            SymbolBadge(symbol: symbol, tint: tint, diameter: 30)
            Text(title)
                .font(.callout.weight(.semibold))
                .padding(.top, 10)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
            action
                .padding(.top, 12)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(width: FrostBarMetrics.statusWidth)
    }
}

/// A small pill button inside the panel (no extra glass layered on the glass).
private struct PillButton: View {
    let title: LocalizedStringKey
    let symbol: String
    var isSpinning = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
                    .symbolEffect(.rotate, options: .speed(1.6), isActive: isSpinning)
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.tint)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color.accentColor.opacity(isHovered ? 0.2 : 0.12), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.16), value: isHovered)
        .disabled(isSpinning)
    }
}
