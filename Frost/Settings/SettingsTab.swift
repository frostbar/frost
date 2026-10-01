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

/// Root of one settings tab: the tab's content over the translucent window background.
struct SettingsPane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(VisualEffectBackground().ignoresSafeArea())
    }
}
