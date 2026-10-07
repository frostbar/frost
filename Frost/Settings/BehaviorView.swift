import FrostCore
import ServiceManagement
import SwiftUI

/// Behavior tab: how hidden icons are shown and rehidden, keeping icons in their sections, launch at login. Grouped
/// form sections like System Settings.
struct BehaviorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences

        Form {
            Section {
                LabeledContent {
                    Picker("Show hidden icons", selection: $preferences.displayMode) {
                        ForEach(Preferences.DisplayMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show hidden icons")
                        DisplayModeExplanation(mode: preferences.displayMode)
                    }
                }
                if model.isMenuBarSupported && preferences.displayMode != .inline && !model.permissions.canManageItems {
                    HStack(spacing: 12) {
                        InlineNotice(text: String(localized: "The Frost Bar needs the Accessibility permission. Until it’s granted, hidden icons expand in the menu bar."),
                                     symbol: "info.circle.fill", tint: .secondary)
                        Spacer(minLength: 0)
                        Button("Grant Access") { model.permissions.requestAccessibility() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
                SettingRow(title: "Automatically rehide",
                           subtitle: "Hides icons again after a delay, or when you click elsewhere.") {
                    Toggle("Automatically rehide", isOn: $preferences.autoRehide)
                        .labelsHidden().toggleStyle(.switch)
                }
                RehideDelayRow(delay: $preferences.autoRehideDelay)
                    .disabled(!preferences.autoRehide)
                    .opacity(preferences.autoRehide ? 1 : 0.5)
                SettingRow(title: "Keep icons in their sections",
                           subtitle: "Moves an app’s icon back when macOS puts it elsewhere.") {
                    Toggle("Keep icons in their sections", isOn: $preferences.keepItemSections)
                        .labelsHidden().toggleStyle(.switch)
                }
            } header: {
                Text("Menu Bar")
            } footer: {
                // Unsupported macOS: the settings are kept for a version that supports it, but change nothing now.
                if !model.isMenuBarSupported {
                    Text(UnsupportedOS.detail)
                }
            }
            .disabled(!model.isMenuBarSupported)

            Section("General") {
                LaunchAtLoginRow()
            }
        }
        .formStyle(.grouped)
        .animation(.snappy, value: preferences.autoRehide)
        .animation(.snappy, value: model.permissions.canManageItems)
        // The notice goes away once Accessibility is granted in System Settings, which may not reactivate Frost.
        .onAppear { if model.isMenuBarSupported { model.permissions.startPolling() } }
        .onDisappear { if model.isMenuBarSupported { model.permissions.stopPolling() } }
    }
}

/// The selected display mode's explanation. All explanations are laid out on top of each other (only the selected one
/// visible), so the row is as tall as the longest one whatever the selection: switching modes never animates the
/// row's height (moving the rows below and resizing the window) or overlaps texts of different line counts. The text
/// switches instantly.
private struct DisplayModeExplanation: View {
    let mode: Preferences.DisplayMode

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Preferences.DisplayMode.allCases, id: \.self) { candidate in
                Text(candidate.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(candidate == mode ? 1 : 0)
                    .accessibilityHidden(candidate != mode)
            }
        }
        .transaction { $0.animation = nil }
    }
}

private struct RehideDelayRow: View {
    @Binding var delay: Double

    var body: some View {
        LabeledContent("Rehide delay") {
            HStack(spacing: 12) {
                Slider(value: $delay, in: 5...60, step: 5) {
                    Text("Rehide delay")
                }
                .labelsHidden()
                .frame(width: 200)
                Text("\(Int(delay)) sec")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }
}

/// Launch at login (`SMAppService.mainApp`). The system is the source of truth: the status is re-read after every
/// change, and failures show an inline error.
private struct LaunchAtLoginRow: View {
    @State private var status = SMAppService.mainApp.status
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Launch at login", isOn: Binding(get: { status == .enabled }, set: setEnabled))
                .toggleStyle(.switch)
            if let errorMessage {
                InlineNotice(text: errorMessage)
            } else if status == .requiresApproval {
                HStack(spacing: 8) {
                    InlineNotice(text: String(localized: "Allow Frost to launch at login in System Settings."),
                                 symbol: "exclamationmark.circle.fill",
                                 tint: .secondary)
                    Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
                        .buttonStyle(.link)
                        .font(.subheadline)
                }
            }
        }
        .animation(.snappy, value: errorMessage)
        .onAppear { status = SMAppService.mainApp.status }
    }

    private func setEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled { try service.register() } else { try service.unregister() }
            errorMessage = nil
        } catch {
            let reason = error.localizedDescription
            errorMessage = enabled
                ? String(localized: "Couldn’t turn on launch at login: \(reason)")
                : String(localized: "Couldn’t turn off launch at login: \(reason)")
        }
        status = service.status
    }
}

extension Preferences.DisplayMode {
    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic", comment: "Display mode")
        case .inline: String(localized: "In Menu Bar", comment: "Display mode")
        case .frostBar: String(localized: "Frost Bar", comment: "Display mode")
        }
    }

    var explanation: String {
        switch self {
        case .automatic: String(localized: "Uses the Frost Bar on displays with a notch, the menu bar elsewhere.")
        case .inline: String(localized: "Hidden icons expand in the menu bar.")
        case .frostBar: String(localized: "Hidden icons appear in a panel below the menu bar.")
        }
    }
}
