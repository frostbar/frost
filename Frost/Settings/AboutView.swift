import FrostCore
import SwiftUI

/// About tab: icon, name, version and permission status.
struct AboutView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let permissions = model.permissions

        ScrollView {
            VStack(spacing: 20) {
                header

                GlassCard {
                    PermissionRow(symbol: "accessibility", tint: .blue, title: String(localized: "Accessibility"),
                                  subtitle: String(localized: "Required. Used to move icons between sections and to click icons in the Frost Bar."),
                                  status: permissions.accessibility ? .granted : .notGranted) {
                        permissions.requestAccessibility()
                    }
                    Divider()
                        .padding(.leading, SettingRow<EmptyView>.textInset)
                    PermissionRow(symbol: "rectangle.dashed.badge.record", tint: .pink, title: String(localized: "Screen Recording"),
                                  subtitle: String(localized: "Optional. Shows real images of icons in the Frost Bar and the layout editor; without it, they appear as app icons. macOS shows a purple dot in the menu bar while Frost captures them."),
                                  status: permissions.screenRecording ? .granted
                                      : permissions.screenRecordingNeedsRelaunch ? .needsRelaunch : .notGranted) {
                        permissions.requestScreenRecording()
                    }
                }

                Text("Hiding and showing icons doesn’t require any permissions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .animation(.snappy, value: permissions.accessibility)
            .animation(.snappy, value: permissions.screenRecording)
            .animation(.snappy, value: permissions.screenRecordingNeedsRelaunch)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Granting access in System Settings does not necessarily reactivate Frost, so poll while visible.
        .onAppear { permissions.startPolling() }
        .onDisappear { permissions.stopPolling() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "snowflake")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.linearGradient(colors: [.cyan, .blue], startPoint: .topLeading,
                                                 endPoint: .bottomTrailing))
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
        return String(localized: "Version \(version)", comment: "About tab: version")
    }
}

private struct PermissionRow: View {
    enum Status {
        case notGranted
        /// Requested, but it takes effect only after a relaunch (Screen Recording).
        case needsRelaunch
        case granted
    }

    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    let status: Status
    let grant: () -> Void

    var body: some View {
        SettingRow(symbol: symbol, tint: tint, title: title,
                   subtitle: status == .needsRelaunch
                       ? String(localized: "Turn on Frost in System Settings, then relaunch.") : subtitle) {
            switch status {
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.green)
                    .font(.callout.weight(.medium))
                    .transition(.blurReplace)
            case .needsRelaunch:
                Button("Relaunch") { AppRelauncher.relaunch() }
                    .buttonStyle(.borderedProminent)
                    .transition(.blurReplace)
            case .notGranted:
                Button("Grant Access", action: grant)
                    .buttonStyle(.borderedProminent)
                    .transition(.blurReplace)
            }
        }
    }
}
