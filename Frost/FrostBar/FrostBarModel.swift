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

    /// Layout to display: the frozen snapshot if any, otherwise the live layout (positions are reliable while collapsed).
    var layout: MenuBarLayout { frozenLayout ?? app.layout }

    var phase: FrostBarState.Phase {
        if !app.permissions.allGranted { return .needsPermission }
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
        var icons: [CGWindowID: NSImage] = [:]
        var widths: [CGWindowID: CGFloat] = [:]
        for item in hidden + alwaysHidden {
            names[item.windowID] = item.displayName
            if images[item.windowID] == nil, let icon = AppIconCache.shared.icon(for: item.bundleID) {
                icons[item.windowID] = icon
            }
            let current = (images[item.windowID] == nil ? nil : sizes[item.windowID]?.width) ?? item.frame.width
            widths[item.windowID] = tileWidths.hold(item.windowID, width: current)
        }
        return FrostBarState(phase: phase, alwaysHidden: alwaysHidden, hidden: hidden, images: images,
                             imageSizes: sizes, contentWidths: widths,
                             styles: app.capturer.styles, templates: app.capturer.templates, names: names,
                             appIcons: icons, maxWidth: maxWidth, maxHeight: maxHeight,
                             isPresented: isPresented, isRefreshing: isRefreshing)
    }
}

/// Root view of the panel; derives its state from the model.
struct FrostBarView: View {
    let model: FrostBarModel
    let actions: FrostBarActions

    var body: some View {
        FrostBarContent(state: model.state, actions: actions)
    }
}
