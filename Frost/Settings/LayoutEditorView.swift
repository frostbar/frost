import FrostCore
import SwiftUI
import UniformTypeIdentifiers

/// Layout tab: three glass section bands showing live captures of the menu bar icons, which can be dragged between
/// sections or reordered.
struct LayoutEditorView: View {
    @Environment(LayoutEditorModel.self) private var editor

    var body: some View {
        LayoutEditorContent(state: editor.state, actions: LayoutEditorActions(
            drop: { id, section, index in Task { await editor.drop(id, into: section, at: index) } },
            grantAccessibility: { editor.grantAccessibility() },
            grantScreenRecording: { editor.grantScreenRecording() },
            relaunch: { AppRelauncher.relaunch() },
            dismissScreenRecordingHint: { editor.dismissScreenRecordingHint() }))
    }
}

// MARK: - Drag state

/// In-view drag state: the dragged item, the section band under the pointer and the insertion position.
struct LayoutDragState: Equatable {
    var draggingID: CGWindowID?
    var targetSection: MenuBarSection?
    /// Insertion position in the list with the dragged item removed (consistent with `InsertionIndex`).
    var hoverIndex: Int?
}

// MARK: - Content

/// Pure presentation: depends only on `LayoutEditorState` and callbacks.
struct LayoutEditorContent: View {
    let state: LayoutEditorState
    let actions: LayoutEditorActions
    @State private var drag: LayoutDragState

    init(state: LayoutEditorState, actions: LayoutEditorActions, initialDrag: LayoutDragState = .init()) {
        self.state = state
        self.actions = actions
        _drag = State(initialValue: initialDrag)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch state.phase {
                case .needsPermission:
                    PermissionPlaceholder(permissions: state.permissions, grant: actions.grantAccessibility)
                case .loading:
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .noWindows:
                    EditorPlaceholder(symbol: "menubar.dock.rectangle.badge.record", tint: .orange,
                                      title: "No Menu Bar Icons Found",
                                      message: "The system didn’t return any menu bar icons.\nFrost will retry automatically. If this keeps happening, try relaunching Frost.") {
                        RetryHint(isRetrying: state.isRetrying)
                    }
                case .controlsMissing:
                    EditorPlaceholder(symbol: "rectangle.split.3x1", tint: .pink,
                                      title: "Can’t Find Frost’s Separator",
                                      message: "Frost’s separator isn’t in the menu bar.\nFrost will retry automatically. If this keeps happening, try relaunching Frost.") {
                        RetryHint(isRetrying: state.isRetrying)
                    }
                case .ready:
                    editor
                }
            }
            .transition(.blurReplace)

            if let message = state.errorMessage {
                ErrorToast(message: message)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: state.phase)
        .animation(.bouncy, value: state.errorMessage)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Icons and captures refresh automatically (see `LayoutEditorModel`), so there is no refresh button.
            Label {
                Text("Drag icons to rearrange them. The menu bar updates to match.")
            } icon: {
                Image(systemName: "hand.draw")
                    .foregroundStyle(.tint)
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            ForEach(MenuBarSection.editorOrder, id: \.self) { section in
                SectionBand(section: section, items: state.layout[section, default: []], state: state,
                            drag: $drag, onDrop: { id, index in actions.drop(id, section, index) })
            }

            Spacer(minLength: 0)

            footer
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
    }

    /// Footer: offers Screen Recording while tiles show app icons (until the user closes that), then explains the badge
    /// when some items are off-screen, otherwise shows a tip.
    @ViewBuilder private var footer: some View {
        let offscreen = state.obscured.count
        VStack(spacing: 8) {
            if state.showsScreenRecordingHint {
                ScreenRecordingNotice(needsRelaunch: state.permissions.screenRecordingNeedsRelaunch,
                                      grant: actions.grantScreenRecording, relaunch: actions.relaunch,
                                      dismiss: actions.dismissScreenRecordingHint)
                    .transition(.opacity)
            }
            if offscreen > 0 {
                Label {
                    Text("\(offscreen) icons are off-screen (e.g. behind the notch) and have no preview, but can still be dragged.")
                } icon: {
                    Image(systemName: "eye.trianglebadge.exclamationmark")
                        .foregroundStyle(.orange)
                }
            } else {
                Label {
                    Text("You can also ⌘-drag icons right in the menu bar. Icons with a lock are fixed by the system.")
                } icon: {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(.yellow)
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .contentTransition(.opacity)
        // The error toast floats in the same spot: make room while it is shown.
        .opacity(state.errorMessage == nil ? 1 : 0)
        .animation(.snappy, value: offscreen)
        .animation(.snappy, value: state.showsScreenRecordingHint)
    }
}

// MARK: - Section bands

extension MenuBarSection {
    /// Top-to-bottom order in the editor.
    static let editorOrder: [MenuBarSection] = [.visible, .hidden, .alwaysHidden]

    var editorTitle: String {
        switch self {
        case .visible: String(localized: "Visible", comment: "Menu bar section")
        case .hidden: String(localized: "Hidden", comment: "Menu bar section")
        case .alwaysHidden: String(localized: "Always Hidden", comment: "Menu bar section")
        }
    }

    var editorSymbol: String {
        switch self {
        case .visible: "eye"
        case .hidden: "eye.slash"
        case .alwaysHidden: "lock"
        }
    }

    var editorTint: Color {
        switch self {
        case .visible: .blue
        case .hidden: .indigo
        case .alwaysHidden: .purple
        }
    }

    var editorExplanation: String {
        switch self {
        case .visible: String(localized: "Always shown in the menu bar")
        case .hidden: String(localized: "Shown when you click the Frost icon")
        case .alwaysHidden: String(localized: "Shown when you ⌥-click the Frost icon")
        }
    }
}

private struct SectionBand: View {
    static let height: CGFloat = 60
    static let cornerRadius: CGFloat = 18
    static let contentInset: CGFloat = 12
    static let tileSpacing: CGFloat = 6

    let section: MenuBarSection
    let items: [MenuBarItem]
    let state: LayoutEditorState
    @Binding var drag: LayoutDragState
    let onDrop: @MainActor (CGWindowID, Int) -> Void

    /// Frame of each tile in the band's content coordinate space (`.named(section)`, moves with horizontal scrolling).
    @State private var tileFrames: [CGWindowID: CGRect] = [:]
    @State private var viewportWidth: CGFloat = 0

    private var isTargeted: Bool { drag.targetSection == section }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            band
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            SymbolBadge(symbol: section.editorSymbol, tint: section.editorTint, diameter: 22)
            Text(section.editorTitle)
                .font(.subheadline.weight(.semibold))
            Text("\(items.count)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(.quaternary, in: .capsule)
                .contentTransition(.numericText())
            Spacer(minLength: 8)
            Text(section.editorExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 2)
        .animation(.snappy, value: items.count)
    }

    private var band: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Self.tileSpacing) {
                ForEach(items) { item in
                    ItemTile(item: item, section: section, state: state,
                             isDragSource: drag.draggingID == item.windowID && drag.targetSection != nil,
                             onDragStart: { drag = LayoutDragState(draggingID: item.windowID) })
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(section)) } action: {
                            tileFrames[item.windowID] = $0
                        }
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(.horizontal, Self.contentInset)
            .frame(minWidth: viewportWidth, minHeight: Self.height, alignment: .leading)
            .overlay(alignment: .topLeading) { insertionMarker }
            .overlay {
                if items.isEmpty {
                    Label("Drop icons here", systemImage: "arrow.down.to.line.compact")
                        .font(.callout)
                        .foregroundStyle(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .contentShape(.rect)
            .coordinateSpace(.named(section))
            .onDrop(of: [.text], delegate: SectionDropDelegate(
                section: section, items: items, tileFrames: tileFrames, drag: $drag, onDrop: onDrop))
            .animation(.snappy, value: items.map(\.windowID))
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        // Fade both ends to hint at horizontal scrolling on overflow (at rest it only covers the insets, not tiles).
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.contentInset - 2)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.contentInset - 2)
            }
        }
        .frame(height: Self.height)
        // Draw the glass in the background instead of wrapping the content in `.glassEffect`: views inside
        // `.glassEffect` never receive drops (VM test on macOS 26.6: the band's `onDrop` was never called until it
        // moved outside the glass layer).
        .background {
            Color.clear
                .glassEffect(isTargeted ? .regular.tint(Color.accentColor.opacity(0.14)) : .regular,
                             in: .rect(cornerRadius: Self.cornerRadius))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(isTargeted ? 1 : 0)
                .allowsHitTesting(false)
        }
        .animation(.snappy(duration: 0.2), value: isTargeted)
    }

    /// A glowing 2 pt bar at the hover position (in the gap between two tiles). Hidden when the drop would not change
    /// the position.
    @ViewBuilder private var insertionMarker: some View {
        if isTargeted, !items.isEmpty, let index = drag.hoverIndex, let x = markerX(for: index) {
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 2, height: 36)
                .shadow(color: Color.accentColor.opacity(0.9), radius: 3)
                .shadow(color: Color.accentColor.opacity(0.6), radius: 8)
                .offset(x: x - 1, y: (Self.height - 36) / 2)
                .allowsHitTesting(false)
                .transition(.opacity)
                .animation(.snappy(duration: 0.18), value: x)
        }
    }

    private func markerX(for index: Int) -> CGFloat? {
        if let current = items.firstIndex(where: { $0.windowID == drag.draggingID }), current == index { return nil }
        let others = items.filter { $0.windowID != drag.draggingID }.compactMap { tileFrames[$0.windowID] }
        guard !others.isEmpty else { return nil }
        let gap = Self.tileSpacing / 2
        if index <= 0 { return others[0].minX - gap }
        if index >= others.count { return others[others.count - 1].maxX + gap }
        return (others[index - 1].maxX + others[index].minX) / 2
    }
}

// MARK: - Drop

private struct SectionDropDelegate: DropDelegate {
    let section: MenuBarSection
    let items: [MenuBarItem]
    let tileFrames: [CGWindowID: CGRect]
    @Binding var drag: LayoutDragState
    let onDrop: @MainActor (CGWindowID, Int) -> Void

    /// The hover marker and the final drop use the same computation: tile midX (content coordinates, scroll included)
    /// -> `InsertionIndex.compute`.
    /// The result never goes past trailing immovable items (clock, Control Center); `DropResolver` also clamps
    /// positions after them to before them.
    private func index(at location: CGPoint) -> Int {
        let draggedIndex = items.firstIndex { $0.windowID == drag.draggingID }
        let mids = items.map { tileFrames[$0.windowID]?.midX ?? 0 }
        let raw = InsertionIndex.compute(dropX: location.x, tileMidXs: mids, draggedIndex: draggedIndex)
        let others = items.filter { $0.windowID != drag.draggingID }
        let limit = (others.lastIndex(where: \.isMovable) ?? -1) + 1
        return min(raw, limit)
    }

    func validateDrop(info: DropInfo) -> Bool {
        drag.draggingID != nil && info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) {
        guard drag.draggingID != nil else { return }
        drag.targetSection = section
        drag.hoverIndex = index(at: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // SwiftUI calls `dropUpdated` once more after `performDrop` (observed in the VM): once the drag state has been
        // cleared, do not re-highlight the band and insertion marker, or the highlight would stick after the drop.
        guard drag.draggingID != nil else { return DropProposal(operation: .move) }
        let index = index(at: info.location)
        if drag.targetSection != section { drag.targetSection = section }
        if drag.hoverIndex != index { drag.hoverIndex = index }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        guard drag.targetSection == section else { return }
        drag.targetSection = nil
        drag.hoverIndex = nil
    }

    /// A cancelled drag (dropped elsewhere) gets no callback, so `draggingID` may be stale; on drop, verify the
    /// payload is that item so text dragged in from other apps cannot trigger a move.
    func performDrop(info: DropInfo) -> Bool {
        guard let expected = drag.draggingID, let provider = info.itemProviders(for: [.text]).first
        else { return false }
        let index = index(at: info.location)
        drag = LayoutDragState()
        let onDrop = onDrop
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? NSString, CGWindowID(string as String) == expected else { return }
            Task { @MainActor in onDrop(expected, index) }
        }
        return true
    }
}

// MARK: - Icon tiles

private struct ItemTile: View {
    static let height: CGFloat = 32
    static let cornerRadius: CGFloat = 10

    let item: MenuBarItem
    let section: MenuBarSection
    let state: LayoutEditorState
    let isDragSource: Bool
    let onDragStart: () -> Void

    @State private var isHovering = false

    private var image: CGImage? { state.images[item.windowID] }
    private var isPending: Bool { state.pending.contains(item.windowID) }
    private var isObscured: Bool { state.obscured.contains(item.windowID) }
    private var name: String { state.names[item.windowID] ?? item.windowTitle }
    private var width: CGFloat { max(item.frame.width, 16) + 8 }

    var body: some View {
        if item.isMovable && !isPending {
            tile.onDrag {
                onDragStart()
                return NSItemProvider(object: String(item.windowID) as NSString)
            } preview: {
                face.frame(width: width, height: Self.height)
            }
        } else {
            tile
        }
    }

    private var tile: some View {
        face
            .frame(width: width, height: Self.height)
            .overlay(alignment: .topTrailing) { badge }
            .overlay {
                if isPending {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.opacity)
                }
            }
            .opacity(opacity)
            .scaleEffect(isHovering && item.isMovable && !isPending ? 1.08 : 1)
            .shadow(color: .black.opacity(isHovering ? 0.22 : 0.1), radius: isHovering ? 6 : 2, y: isHovering ? 3 : 1)
            .onHover { isHovering = $0 }
            .animation(.snappy(duration: 0.18), value: isHovering)
            .animation(.snappy, value: isPending)
            .animation(.snappy(duration: 0.2), value: isDragSource)
            .help(helpText)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isImage)
            .accessibilityLabel(state.accessibilityLabels[item.windowID] ?? name)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(item.isMovable ? String(localized: "Drag to move it to another position or section.") : "")
    }

    /// Capture / fallback icon (`ItemGlyph`) on a plate chosen by glyph brightness.
    private var face: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        // A placeholder that gets its first real capture cross-fades instead of swapping in one frame (both layers
        // stay in the hierarchy, only their opacity animates); later captures of the same item update in place.
        return ZStack {
            ItemGlyph(item: item, image: nil, appIcon: state.appIcons[item.windowID],
                      imageSize: state.imageSizes[item.windowID], label: state.fallbackLabels[item.windowID])
                .opacity(image == nil ? 1 : 0)
            ItemGlyph(item: item, image: image, appIcon: nil, imageSize: state.imageSizes[item.windowID])
                .opacity(image == nil ? 0 : 1)
        }
            .frame(width: width, height: Self.height)
            .background(background, in: shape)
            .animation(.easeOut(duration: 0.15), value: image != nil)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
    }

    private var background: Color {
        guard image != nil, let tone = state.tones[item.windowID] else { return Color.primary.opacity(0.07) }
        return tone.plateColor
    }

    @ViewBuilder private var badge: some View {
        if !item.isMovable {
            TileBadge(symbol: "lock.fill", tint: .gray)
        } else if isObscured {
            TileBadge(symbol: "eye.trianglebadge.exclamationmark", tint: .orange)
        }
    }

    private var opacity: Double {
        if !item.isMovable { return 0.5 }
        if isDragSource { return 0.3 }
        if isPending { return 0.6 }
        return 1
    }

    /// The tile's section and state for VoiceOver, e.g. "Hidden, doesn’t fit in the menu bar".
    private var accessibilityValue: String {
        let section = section.editorTitle
        let detail: String? = if isPending {
            String(localized: "moving", comment: "VoiceOver: state of an icon in the layout editor")
        } else if !item.isMovable {
            String(localized: "fixed by the system", comment: "VoiceOver: state of an icon in the layout editor")
        } else if isObscured {
            String(localized: "doesn’t fit in the menu bar",
                   comment: "VoiceOver: state of an icon in the layout editor")
        } else {
            nil
        }
        guard let detail else { return section }
        return String(localized: "\(section), \(detail)",
                      comment: "VoiceOver value of an icon in the layout editor: its section, then its state")
    }

    private var helpText: String {
        if !item.isMovable { return String(localized: "\(name) (fixed by the system; can’t be moved)", comment: "Tile tooltip; the argument is the icon name") }
        if isObscured { return String(localized: "\(name) (doesn’t fit in the menu bar)", comment: "Tile tooltip; the argument is the icon name") }
        return name
    }
}

/// Small round badge in the tile's top-right corner.
private struct TileBadge: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 14, height: 14)
            .background(tint.gradient, in: .circle)
            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
            .offset(x: 4, y: -4)
            .accessibilityHidden(true)
    }
}

// MARK: - Placeholders, hints, toast

/// Auto-retry hint in the error placeholders. Shows progress only while a retry is actually running (no
/// continuously running animations); a static icon otherwise.
private struct RetryHint: View {
    let isRetrying: Bool

    var body: some View {
        Label {
            Text("Retrying automatically…")
        } icon: {
            Group {
                if isRetrying {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .frame(width: 14, height: 14)
            .transition(.opacity)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: .capsule)
        .animation(.snappy(duration: 0.2), value: isRetrying)
        .accessibilityElement(children: .combine)
    }
}

/// Centered glass card: large badge, title, message and actions.
private struct EditorPlaceholder<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            SymbolBadge(symbol: symbol, tint: tint, diameter: 56)
            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
                .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: 400)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }
}

private struct PermissionPlaceholder: View {
    let permissions: LayoutEditorState.Permissions
    /// Requests Accessibility (the system prompt and System Settings).
    let grant: () -> Void

    var body: some View {
        EditorPlaceholder(symbol: "lock.shield", tint: .orange, title: "Accessibility Required",
                          message: "Frost needs the Accessibility permission to read and move icons. Screen Recording is optional: it shows real images of the icons.") {
            VStack(spacing: 16) {
                HStack(spacing: 18) {
                    status("Accessibility", granted: permissions.accessibility)
                    status("Screen Recording (optional)", granted: permissions.screenRecording)
                }
                Button("Grant Access", action: grant)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .animation(.snappy, value: permissions)
    }

    private func status(_ title: LocalizedStringKey, granted: Bool) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
        }
        .font(.callout.weight(.medium))
    }
}

/// Screen Recording isn't granted: tiles show app icons. A footer line offering real images (requests Screen
/// Recording; once requested, offers the relaunch it needs), with a close button that hides it for good.
private struct ScreenRecordingNotice: View {
    let needsRelaunch: Bool
    let grant: () -> Void
    let relaunch: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if needsRelaunch {
                Label {
                    Text("Turn on Frost in System Settings, then relaunch.")
                } icon: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.orange)
                }
                Button("Relaunch", action: relaunch)
                    .buttonStyle(.link)
                    // The footer's secondary style would make it look like plain text.
                    .foregroundStyle(.tint)
            } else {
                Button(action: grant) {
                    Label {
                        Text("Grant Screen Recording to see real icons")
                    } icon: {
                        Image(systemName: "rectangle.dashed.badge.record")
                            .foregroundStyle(.pink)
                    }
                }
                .buttonStyle(.link)
                .accessibilityHint("Opens System Settings")
            }
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Don’t show again"))
            .accessibilityLabel("Don’t show again")
        }
    }
}

private struct ErrorToast: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .symbolRenderingMode(.multicolor)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .glassEffect(.regular.tint(.red.opacity(0.3)), in: .capsule)
            .accessibilityAddTraits(.isStaticText)
    }
}
