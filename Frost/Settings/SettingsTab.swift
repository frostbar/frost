import SwiftUI

/// The settings window's tabs, shown as toolbar items in the standard macOS settings window style.
enum SettingsTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case layout, behavior, about

    var id: Self { self }

    /// Toolbar item label, and the window title while the tab is selected.
    var title: String {
        switch self {
        case .layout: String(localized: "Layout", comment: "Settings tab")
        case .behavior: String(localized: "Behavior", comment: "Settings tab")
        case .about: String(localized: "About", comment: "Settings tab")
        }
    }

    var symbol: String {
        switch self {
        case .layout: "square.grid.3x1.below.line.grid.1x2"
        case .behavior: "slider.horizontal.3"
        case .about: "info.circle"
        }
    }
}

/// Root of one settings tab: the tab's content filling the content area. It has no background of its own: the window's
/// translucent background lies behind all tabs (see `SettingsWindowController`), so only the content cross-fades.
///
/// The pane starts at the toolbar's bottom edge. The space between the toolbar and the content is an empty top bar
/// rather than padding, so a tab that scrolls (larger text, a long translation) gets the standard scroll edge effect
/// there: content scrolling up disappears under the bar's hard edge (the style for a toolbar with text labels) instead
/// of being cut off at the pane's edge.
struct SettingsPane<Content: View>: View {
    /// Space between the toolbar and the tab's content.
    static var topSpacing: CGFloat { 12 }

    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollEdgeEffectStyle(.hard, for: .top)
            .safeAreaBar(edge: .top, spacing: 0) {
                Color.clear.frame(height: Self.topSpacing)
            }
    }
}
