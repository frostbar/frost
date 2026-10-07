import FrostCore
import SwiftUI

/// About tab: app icon, name and version, update settings and permission status.
struct AboutView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let permissions = model.permissions
        @Bindable var updates = model.updates

        VStack(spacing: 0) {
            header
                .padding(.top, 8)

            Form {
                Section("Updates") {
                    SettingRow(title: "Automatically check for updates",
                               subtitle: "Checks GitHub Releases once a day and asks before installing.") {
                        Toggle("Automatically check for updates", isOn: $updates.automaticallyChecksForUpdates)
                            .labelsHidden().toggleStyle(.switch)
                    }
                    LabeledContent {
                        Button("Check for Updates…") { updates.checkForUpdates() }
                            .disabled(!updates.canCheckForUpdates)
                    } label: {
                        Text(Self.lastCheckedText(updates.lastUpdateCheckDate))
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    PermissionRow(title: "Accessibility",
                                  subtitle: "Required to move icons and to click them in the Frost Bar.",
                                  status: permissions.accessibility ? .granted : .notGranted,
                                  grant: { permissions.requestAccessibility() })
                    PermissionRow(title: "Screen Recording",
                                  subtitle: "Optional. Shows real icon images instead of app icons. macOS shows a purple dot in the menu bar while Frost captures them.",
                                  status: permissions.screenRecording ? .granted
                                      : permissions.screenRecordingNeedsRelaunch ? .needsRelaunch : .notGranted,
                                  grant: { permissions.requestScreenRecording() },
                                  openSettings: { permissions.openScreenRecordingSettings() })
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("Hiding and showing icons doesn’t require any permissions.")
                }
            }
            .formStyle(.grouped)
        }
        .animation(.snappy, value: permissions.accessibility)
        .animation(.snappy, value: permissions.screenRecording)
        .animation(.snappy, value: permissions.screenRecordingNeedsRelaunch)
        // Granting access in System Settings does not necessarily reactivate Frost, so poll while visible.
        .onAppear { permissions.startPolling() }
        .onDisappear { permissions.stopPolling() }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Frost")
                .font(.title.weight(.semibold))
            Text(Self.versionString)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    /// "Last checked: today at 15:58" (the system's relative date style, in the language of Frost's UI with the user's
    /// region settings, `UILocale`), or "Never checked".
    private static func lastCheckedText(_ date: Date?) -> String {
        guard let date else { return String(localized: "Never checked") }
        let formatter = DateFormatter()
        formatter.locale = UILocale.app
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return String(localized: "Last checked: \(formatter.string(from: date))")
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

    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let status: Status
    let grant: () -> Void
    /// Opens System Settings' pane for this permission (only used while a relaunch is pending).
    var openSettings: () -> Void = {}

    var body: some View {
        SettingRow(title: title,
                   subtitle: status == .needsRelaunch ? "Turn on Frost in System Settings, then relaunch." : subtitle) {
            switch status {
            case .granted:
                // Only the checkmark is colored; the word is plain secondary text.
                Label {
                    Text("Granted")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.green)
                }
                .font(.callout)
                    .transition(.blurReplace)
            case .needsRelaunch:
                // A user who denied the prompt (or closed it) still has to flip the switch first; this gets them to
                // the pane without giving up the relaunch, which stays the primary action.
                HStack(spacing: 8) {
                    Button("Open System Settings", action: openSettings)
                    Button("Relaunch") { AppRelauncher.relaunch() }
                        .buttonStyle(.borderedProminent)
                }
                .fixedSize()
                .transition(.blurReplace)
            case .notGranted:
                Button("Grant Access", action: grant)
                    .buttonStyle(.borderedProminent)
                    .transition(.blurReplace)
            }
        }
    }
}
