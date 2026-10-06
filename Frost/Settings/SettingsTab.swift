import SwiftUI

/// The settings window's tabs, shown as toolbar items in the standard macOS settings window style.
enum SettingsTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case layout, behavior, about

    var id: Self { self }

    private static let lastSelectedKey = "settingsTab"

    /// The tab the settings window opens on when the caller doesn't ask for one: the one the user last had selected
    /// (Layout on the first run).
    static var lastSelected: SettingsTab {
        get { UserDefaults.standard.string(forKey: lastSelectedKey).flatMap(SettingsTab.init(rawValue:)) ?? .layout }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: lastSelectedKey) }
    }

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

/// Reports the content height of one settings tab to its container (see `SettingsTabContainerController`).
@MainActor
final class SettingsHeightReporter {
    /// The tab's content height as last measured by SwiftUI; nil until the first layout.
    private(set) var height: CGFloat?
    var onChange: ((CGFloat) -> Void)?

    func report(_ newHeight: CGFloat) {
        guard newHeight > 0, newHeight != height else { return }
        height = newHeight
        onChange?(newHeight)
    }
}

/// Root of one settings tab: the content at the window's fixed width. It has no background of its own (the window's
/// standard background lies behind all tabs), so only the content cross-fades.
///
/// The window's height follows the selected tab: a tab is as tall as its content, which it reports through `reporter`
/// (also when the content changes while the tab is shown, e.g. a notice appearing). The content sits at the top of whatever space the window gives it, so resizing the
/// window never moves or relayouts it.
struct SettingsPane<Content: View>: View {
    static var width: CGFloat { 640 }

    let reporter: SettingsHeightReporter
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: Self.width)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { reporter.report($0) }
    }
}
