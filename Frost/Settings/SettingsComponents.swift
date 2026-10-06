import SwiftUI

/// Circular SF Symbol badge (colored gradient with a white glyph).
struct SymbolBadge: View {
    static let size: CGFloat = 28

    let symbol: String
    let tint: Color
    var diameter: CGFloat = Self.size

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: (diameter * 13 / 28).rounded(), weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(tint.gradient, in: .circle)
            .accessibilityHidden(true)
    }
}

/// A row of a grouped settings form: title (and an optional one-line explanation below it) on the left, the control on
/// the right.
struct SettingRow<Accessory: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        LabeledContent {
            accessory
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A small inline notice (error / warning) inside a form row.
struct InlineNotice: View {
    let text: String
    var symbol = "exclamationmark.triangle.fill"
    var tint: Color = .red

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.subheadline)
        .foregroundStyle(tint)
        .transition(.opacity)
    }
}
