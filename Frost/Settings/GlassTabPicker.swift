import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case layout, behavior, about

    var id: Self { self }

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

/// Capsule segmented control at the top of the settings window: each segment is a piece of glass in one shared
/// `GlassEffectContainer` so they blend together; the selection is tinted and the glass morphs when it changes.
struct GlassTabPicker: View {
    @Binding var selection: SettingsTab
    @Namespace private var namespace

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    let isSelected = selection == tab
                    Button {
                        withAnimation(.bouncy) { selection = tab }
                    } label: {
                        Label(tab.title, systemImage: tab.symbol)
                            .symbolRenderingMode(.hierarchical)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(isSelected ? .regular.tint(.accentColor.opacity(0.35)).interactive()
                                            : .regular.interactive(),
                                 in: .capsule)
                    .glassEffectID(tab, in: namespace)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }
}
