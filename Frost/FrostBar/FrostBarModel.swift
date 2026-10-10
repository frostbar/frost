import FrostCore
import Observation
import SwiftUI

/// Observable state shared by the controller and the view. `state` is derived live from the app's services (the view
/// refreshes when the layout, captures, or permissions change).
@Observable
@MainActor
final class FrostBarModel {
    var showAlwaysHidden = false
    var isPresented = false
    var isRefreshing = false
    /// The Always Hidden section is fading out before the panel shrinks (see `FrostBarController.toggle`).
    var isAlwaysHiddenFading = false
    /// Maximum size of the panel's visible content (computed per screen by the controller).
    var maxWidth: CGFloat = 800
    var maxHeight: CGFloat = 800
    /// Layout frozen on screen while a temporary expansion captures missing screenshots (positions near the notch aren't
    /// reliable while expanded, and freezing keeps icons from jumping).
    var frozenLayout: MenuBarLayout?

    @ObservationIgnored private unowned let app: AppModel
    /// Each tile's widest width this session (see `TileWidthMemory`). Updated while deriving `state`: holding a width
    /// changes nothing on screen, so it needn't be observed.
    @ObservationIgnored private var tileWidths = TileWidthMemory()

    init(app: AppModel) {
        self.app = app
    }

    /// The panel is opening: tile widths start over (items may have changed size while it was closed).
    func beginSession() {
        tileWidths.reset()
    }

    /// The panel shows the user's Hidden section, plus Always Hidden on Option-click. On macOS 27 the
    /// arrangement is persisted independently of transient AX geometry, just as it is in the layout editor.
    var layout: MenuBarLayout {
        frozenLayout ?? app.layout
    }

    var phase: FrostBarState.Phase {
        // Accessibility is enough; without Screen Recording tiles show app icons (`ItemFallbackAppearance`).
        if !app.permissions.canManageItems { return .needsPermission }
        switch app.scanner.status {
        case .notScanned: return .loading
        case .noWindows: return .unreadable
        case .ok:
            let layout = layout
            if layout.isEmpty { return .unreadable }
            let count = layout[.hidden, default: []].count
                + (showAlwaysHidden ? layout[.alwaysHidden, default: []].count : 0)
            return count == 0 ? .empty : .ready
        }
    }

    var state: FrostBarState {
        let layout = layout
        let alwaysHidden = showAlwaysHidden ? layout[.alwaysHidden, default: []] : []
        let hidden = layout[.hidden, default: []]
        let images = app.capturer.images
        let sizes = app.capturer.sizes
        var names: [CGWindowID: String] = [:]
        var accessibilityLabels: [CGWindowID: String] = [:]
        var icons: [CGWindowID: NSImage] = [:]
        var widths: [CGWindowID: CGFloat] = [:]
        let shown = hidden + alwaysHidden
        let labels = ItemFallbackAppearance.labels(for: shown.filter { images[$0.windowID] == nil })
        for item in shown {
            names[item.windowID] = item.displayName
            accessibilityLabels[item.windowID] = item.accessibilityName
            if images[item.windowID] == nil, let icon = AppIconCache.shared.icon(for: item.bundleID) {
                icons[item.windowID] = icon
            }
            // Without an image the tile is as wide as its label needs (a short text item shows in full).
            let current = (images[item.windowID] == nil ? nil : sizes[item.windowID]?.width)
                ?? FallbackLabelMetrics.tileWidth(for: item, label: labels[item.windowID])
            widths[item.windowID] = tileWidths.hold(item.windowID, width: current)
        }
        return FrostBarState(showsItemCount: app.backend != .accessibility,
                             phase: phase, alwaysHidden: alwaysHidden, hidden: hidden, images: images,
                             imageSizes: sizes, contentWidths: widths, accessibilityLabels: accessibilityLabels,
                             fallbackLabels: labels,
                             styles: app.capturer.styles, templates: app.capturer.templates, names: names,
                             appIcons: icons, maxWidth: maxWidth, maxHeight: maxHeight,
                             isPresented: isPresented, isRefreshing: isRefreshing,
                             isAlwaysHiddenFading: isAlwaysHiddenFading,
                             showsScreenRecordingHint: app.preferences.showsScreenRecordingHint(
                                app.permissions.capabilities),
                             screenRecordingNeedsRelaunch: app.permissions.screenRecordingNeedsRelaunch)
    }
}

/// Root view of the panel; derives its state from the model.
struct FrostBarView: View {
    let model: FrostBarModel
    let actions: FrostBarActions

    var body: some View {
        TopTrailingPin {
            FrostBarContent(state: model.state, actions: actions)
        }
    }
}

/// Lays its content out at its ideal size, pinned to the top-trailing corner (where the panel hangs from the menu bar
/// and the Frost icon), whatever size the hosting view has: when the content's size changes, it never moves. The
/// panel window can be larger than the content (it shrinks after a section has faded out) or, for a frame, smaller (it
/// grows as soon as AppKit learns the new size); a plain frame would center content larger than the view, drawing it
/// shifted for a frame, or animate its position when the change is animated (⌥-click), sliding the whole panel.
/// Its ideal size (the hosting view's intrinsic size, which sizes the window) is the content's.
private struct TopTrailingPin: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(width: proposal.width ?? ideal.width, height: proposal.height ?? ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            subview.place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing,
                          proposal: ProposedViewSize(size))
        }
    }
}
