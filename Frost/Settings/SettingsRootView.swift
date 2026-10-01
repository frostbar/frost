import Observation
import SwiftUI

/// The settings window's selected tab. Owned by the window controller so others (onboarding, the main menu's About
/// item) can switch an already open window to a given tab.
@Observable
@MainActor
final class SettingsNavigation {
    var tab: SettingsTab

    init(tab: SettingsTab = .layout) {
        self.tab = tab
    }
}

/// Settings window root view: glass segmented control in the title bar area plus the content for the selected tab.
struct SettingsRootView: View {
    @Environment(LayoutEditorModel.self) private var layoutEditor
    @Bindable var navigation: SettingsNavigation

    static let titlebarHeight: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            // Centered on the same row as the traffic lights: the window uses fullSizeContentView, so content extends
            // under the title bar; the title bar (compact toolbar) is 40 pt tall and the control is centered in it.
            GlassTabPicker(selection: $navigation.tab)
                .frame(maxWidth: .infinity)
                .frame(height: Self.titlebarHeight)
                .padding(.bottom, 12)

            ZStack {
                switch navigation.tab {
                case .layout:
                    LayoutEditorView()
                        .transition(.blurReplace)
                case .behavior:
                    BehaviorView()
                        .transition(.blurReplace)
                case .about:
                    AboutView()
                        .transition(.blurReplace)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(edges: .top)
        // Leaving the Layout tab ends editing (collapsing the menu bar); returning re-enters editing. Driven by the
        // selected tab rather than the Layout tab's onAppear/onDisappear, which do not always fire in pairs when the
        // window closes and reopens (the window controller reports window open/close separately).
        .onChange(of: navigation.tab, initial: true) { _, tab in
            layoutEditor.setTabSelected(tab == .layout)
        }
        .frame(minWidth: 640, idealWidth: 640, minHeight: 520, idealHeight: 520)
        .background(VisualEffectBackground().ignoresSafeArea())
    }
}
