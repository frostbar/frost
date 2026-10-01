import FrostCore
import SwiftUI

/// About tab: icon, name, version and permission status.
struct AboutView: View {
    @Environment(AppModel.self) private var model
    /// Toggled once on appear so the snowflake plays a one-shot animation (no continuously running animations in windows).
    @State private var greet = false

    var body: some View {
        let permissions = model.permissions

        ScrollView {
            VStack(spacing: 20) {
                header

                GlassCard {
                    PermissionRow(symbol: "accessibility", tint: .blue, title: String(localized: "Accessibility"),
                                  subtitle: String(localized: "Used to move icons between sections and to click icons in the Frost Bar."),
                                  isGranted: permissions.accessibility) {
                        model.openOnboarding()
                    }
                    Divider()
                        .padding(.leading, SettingRow<EmptyView>.textInset)
                    PermissionRow(symbol: "rectangle.dashed.badge.record", tint: .pink, title: String(localized: "Screen Recording"),
                                  subtitle: String(localized: "Used to show images of icons in the Frost Bar and the layout editor."),
                                  isGranted: permissions.screenRecording) {
                        model.openOnboarding()
                    }
                }

                Text("Hiding and showing icons doesn’t require any permissions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String {
                    Text(copyright)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 0)
            .padding(.bottom, 20)
            .animation(.snappy, value: permissions.accessibility)
            .animation(.snappy, value: permissions.screenRecording)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Granting access in System Settings does not necessarily reactivate Frost, so poll while visible.
        .onAppear {
            permissions.startPolling()
            greet.toggle()
        }
        .onDisappear { permissions.stopPolling() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "snowflake")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.linearGradient(colors: [.cyan, .blue], startPoint: .topLeading,
                                                 endPoint: .bottomTrailing))
                .symbolEffect(.bounce, value: greet)
                .frame(width: 96, height: 96)
                .background {
                    Circle()
                        .fill(Color.cyan.opacity(0.18))
                        .blur(radius: 24)
                }
                .accessibilityHidden(true)
            Text("Frost")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text(Self.versionString)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.top, 4)
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return String(localized: "Version \(version) (\(build))", comment: "About tab: version (build number)")
    }
}

private struct PermissionRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    let isGranted: Bool
    let grant: () -> Void

    var body: some View {
        SettingRow(symbol: symbol, tint: tint, title: title, subtitle: subtitle) {
            if isGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.green)
                    .font(.callout.weight(.medium))
                    .transition(.blurReplace)
            } else {
                Button("Grant Access", action: grant)
                    .buttonStyle(.glassProminent)
                    .tint(.orange)
                    .transition(.blurReplace)
            }
        }
    }
}
