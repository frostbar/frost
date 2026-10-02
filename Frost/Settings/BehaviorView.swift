import FrostCore
import ServiceManagement
import SwiftUI

/// Behavior tab: launch at login, automatic rehide, display mode, automatic update checks.
struct BehaviorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences

        ScrollView {
            VStack(spacing: 16) {
                GlassCard {
                    LaunchAtLoginRow()
                }

                GlassCard {
                    SettingRow(symbol: "eye.slash", tint: .indigo, title: String(localized: "Automatically rehide"),
                               subtitle: String(localized: "Hide icons again after a delay. Clicking outside the menu bar hides them right away.")) {
                        Toggle("Automatically rehide", isOn: $preferences.autoRehide)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    Divider()
                        .padding(.leading, SettingRow<EmptyView>.textInset)
                    RehideDelayRow(delay: $preferences.autoRehideDelay)
                        .disabled(!preferences.autoRehide)
                        .opacity(preferences.autoRehide ? 1 : 0.5)
                }

                GlassCard {
                    SettingRow(symbol: "menubar.rectangle", tint: .blue, title: String(localized: "Show hidden icons")) {
                        Picker("Show hidden icons", selection: $preferences.displayMode) {
                            ForEach(Preferences.DisplayMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    DisplayModeExplanation(mode: preferences.displayMode)
                        .padding(.leading, SettingRow<EmptyView>.textInset)
                    if preferences.displayMode != .inline && !model.permissions.allGranted {
                        InlineNotice(text: String(localized: "The Frost Bar needs Accessibility and Screen Recording permissions. Until they’re granted, hidden icons expand in the menu bar."),
                                     symbol: "info.circle.fill", tint: .orange)
                    }
                }

                GlassCard {
                    UpdatesRow(updates: model.updates)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .animation(.snappy, value: preferences.displayMode)
            .animation(.snappy, value: preferences.autoRehide)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// The selected display mode's explanation. All explanations are laid out on top of each other (only the selected one
/// visible), so the card is as tall as the longest one whatever the selection: switching modes never animates the
/// card's height (pushing the cards below) or overlaps texts of different line counts. The text switches instantly.
private struct DisplayModeExplanation: View {
    let mode: Preferences.DisplayMode

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Preferences.DisplayMode.allCases, id: \.self) { candidate in
                Text(candidate.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        HStack(spacing: 12) {
            Text("Rehide delay")
            Spacer(minLength: 12)
            Slider(value: $delay, in: 5...60, step: 5) {
                Text("Rehide delay")
            }
            .labelsHidden()
            .frame(width: 240)
            Text("\(Int(delay)) sec")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.leading, SettingRow<EmptyView>.textInset)
    }
}

/// Automatic update checks (Sparkle) and Check Now.
private struct UpdatesRow: View {
    @Bindable var updates: UpdateController

    var body: some View {
        SettingRow(symbol: "arrow.down.circle", tint: .teal, title: String(localized: "Automatically check for updates"),
                   subtitle: String(localized: "Checks GitHub Releases once a day and asks before installing an update.")) {
            HStack(spacing: 12) {
                Button("Check Now") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
                Toggle("Automatically check for updates", isOn: $updates.automaticallyChecksForUpdates)
                    .toggleStyle(.switch)
                    .labelsHidden()
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
            SettingRow(symbol: "power", tint: .green, title: String(localized: "Launch at login"),
                       subtitle: String(localized: "Open Frost automatically when you log in to your Mac.")) {
                Toggle("Launch at login", isOn: Binding(get: { status == .enabled }, set: setEnabled))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            if let errorMessage {
                InlineNotice(text: errorMessage)
            } else if status == .requiresApproval {
                HStack(spacing: 8) {
                    InlineNotice(text: String(localized: "Allow Frost to launch at login in System Settings."),
                                 symbol: "exclamationmark.circle.fill",
                                 tint: .orange)
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
        case .automatic: String(localized: "Automatic: uses the Frost Bar on displays with a notch and expands in the menu bar on other displays.")
        case .inline: String(localized: "In Menu Bar: hidden icons expand right in the menu bar.")
        case .frostBar: String(localized: "Frost Bar: hidden icons appear in a glass panel below the menu bar.")
        }
    }
}
