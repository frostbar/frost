import SwiftUI

/// A glass card grouping rows on a settings tab.
struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

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

/// A settings row: badge and title / subtitle on the left, control on the right.
struct SettingRow<Accessory: View>: View {
    /// Spacing between badge and text; extra content below a row aligns with the title using `textInset`.
    static var spacing: CGFloat { 12 }
    static var textInset: CGFloat { SymbolBadge.size + spacing }

    let symbol: String
    let tint: Color
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: Self.spacing) {
            SymbolBadge(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory
        }
    }
}

/// A small inline notice (error / warning), aligned with the row title.
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
        .padding(.leading, SettingRow<EmptyView>.textInset)
        .transition(.opacity)
    }
}
