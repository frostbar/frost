import FrostCore
import SwiftUI

/// Data the onboarding view draws from (a value type: the view does not depend on services directly, so it can be
/// rendered offscreen with fake data).
struct OnboardingState: Equatable {
    var accessibility: Bool
    var screenRecording: Bool
    /// The user clicked Grant for Screen Recording: `CGPreflightScreenCaptureAccess` only reflects a new grant after
    /// a relaunch.
    var screenRecordingRequested: Bool
    /// First run with existing icons in the Always Hidden section: once all permissions are granted they are moved to
    /// the Hidden section automatically (see `NewItemPlacer`).
    var firstRunPlacementPending = false

    var allGranted: Bool { accessibility && screenRecording }
    var needsRelaunch: Bool { screenRecordingRequested && !screenRecording }
    /// Explains where existing icons are for now while permissions are incomplete and no relaunch is pending.
    var showsPlacementNote: Bool { firstRunPlacementPending && !allGranted && !needsRelaunch }
}

/// Actions emitted by the onboarding view.
struct OnboardingActions {
    var grantAccessibility: @MainActor () -> Void
    var grantScreenRecording: @MainActor () -> Void
    var relaunch: @MainActor () -> Void
    /// Closes onboarding (Not Now / Done).
    var dismiss: @MainActor () -> Void
    /// Closes onboarding and opens the Layout tab of the settings window.
    var openLayoutEditor: @MainActor () -> Void

    static let none = OnboardingActions(grantAccessibility: {}, grantScreenRecording: {}, relaunch: {},
                                        dismiss: {}, openLayoutEditor: {})
}

/// Root view of the onboarding window: reads permission state from `AppModel`.
struct OnboardingRootView: View {
    @Environment(AppModel.self) private var model
    let session: OnboardingSession
    let actions: OnboardingActions

    var body: some View {
        OnboardingView(state: OnboardingState(accessibility: model.permissions.accessibility,
                                              screenRecording: model.permissions.screenRecording,
                                              screenRecordingRequested: session.screenRecordingRequested,
                                              firstRunPlacementPending: firstRunPlacementPending),
                       actions: actions)
    }

    /// First run, and the Always Hidden section really has existing icons (the system puts icons without a saved
    /// position there; determined from window frames, which needs no permissions).
    private var firstRunPlacementPending: Bool {
        model.newItems.isFirstRunPlacementPending && !model.layout[.alwaysHidden, default: []].isEmpty
    }
}

/// Permissions onboarding: gradient snowflake header, two glass permission cards, a relaunch or next-step notice when
/// needed, and footer buttons.
struct OnboardingView: View {
    let state: OnboardingState
    let actions: OnboardingActions

    /// Size of the whole window (including the transparent title bar area).
    static let size = CGSize(width: 520, height: 560)

    /// Toggled once on appear so the snowflake plays a one-shot animation (no continuously running animations in
    /// windows).
    @State private var greet = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 34)
                .padding(.bottom, 22)

            Text("Frost needs these two permissions to arrange and show your menu bar icons.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.bottom, 10)

            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 12) {
                    PermissionCard(symbol: "accessibility", tint: .blue, title: "Accessibility",
                                   detail: "Used to move and click menu bar icons.",
                                   isGranted: state.accessibility, grant: actions.grantAccessibility)
                    PermissionCard(symbol: "rectangle.dashed.badge.record", tint: .pink, title: "Screen Recording",
                                   detail: "Used to show icons in the Frost Bar and the layout editor.",
                                   isGranted: state.screenRecording, grant: actions.grantScreenRecording)
                }
            }

            ZStack {
                if state.needsRelaunch {
                    RelaunchNotice(relaunch: actions.relaunch)
                        .transition(.blurReplace.combined(with: .move(edge: .top)))
                } else if state.allGranted {
                    NextStepNotice()
                        .transition(.blurReplace.combined(with: .move(edge: .top)))
                } else if state.showsPlacementNote {
                    PlacementNote()
                        .transition(.opacity)
                }
            }
            .padding(.top, 14)

            Spacer(minLength: 12)

            footer
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(duration: 0.45, bounce: 0.2), value: state)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "snowflake")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.linearGradient(colors: [.cyan, .blue], startPoint: .topLeading,
                                                 endPoint: .bottomTrailing))
                .symbolEffect(.bounce, value: greet)
                .onAppear { greet.toggle() }
                .frame(width: 84, height: 84)
                .background {
                    Circle()
                        .fill(Color.cyan.opacity(0.2))
                        .blur(radius: 26)
                }
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            Text("Welcome to Frost")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text("Keep your menu bar tidy")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Label("Hiding icons needs no permissions", systemImage: "lock.open")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Spacer(minLength: 8)
            if state.allGranted {
                Button("Done", action: actions.dismiss)
                    .buttonStyle(.glass)
                    .controlSize(.large)
                Button(action: actions.openLayoutEditor) {
                    Label("Open Layout Editor", systemImage: "arrow.right")
                        .labelStyle(TrailingIconLabelStyle())
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Not Now", action: actions.dismiss)
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}

// MARK: - Cards

private struct PermissionCard: View {
    let symbol: String
    let tint: Color
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let isGranted: Bool
    let grant: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            SymbolBadge(symbol: symbol, tint: tint, diameter: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                if isGranted {
                    GrantedCheckmark()
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                } else {
                    Button("Grant", action: grant)
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .transition(.blurReplace)
                }
            }
            .frame(minWidth: 72, alignment: .trailing)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .glassEffect(isGranted ? .regular.tint(.green.opacity(0.12)) : .regular, in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .combine)
        .accessibilityValue(isGranted ? Text("Granted") : Text("Not granted"))
    }
}

/// Green checkmark for a granted permission: bounces once when it appears.
private struct GrantedCheckmark: View {
    @State private var bounce = false

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .green)
            .font(.system(size: 30, weight: .semibold))
            .symbolEffect(.bounce, value: bounce)
            .onAppear { bounce.toggle() }
            .accessibilityLabel("Granted")
    }
}

/// After requesting Screen Recording: Frost must be relaunched for it to take effect.
private struct RelaunchNotice: View {
    let relaunch: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SymbolBadge(symbol: "arrow.clockwise", tint: .orange, diameter: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Relaunch Frost after granting access")
                    .font(.callout.weight(.semibold))
                Text("Turn on Frost in System Settings, then relaunch.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Relaunch", action: relaunch)
                .buttonStyle(.glass)
                .tint(.orange)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .glassEffect(.regular.tint(.orange.opacity(0.14)), in: .rect(cornerRadius: 18))
    }
}

/// First run, not yet granted: existing icons stay in the Always Hidden section for now and move to the Hidden
/// section once granted. A single line, not a card.
private struct PlacementNote: View {
    var body: some View {
        Label {
            Text("Existing icons stay in Always Hidden until access is granted, then move to Hidden automatically (Screen Recording requires relaunching Frost).")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

/// After everything is granted: explains that existing icons start out in the Hidden section and points the user to
/// the layout editor.
private struct NextStepNotice: View {
    var body: some View {
        HStack(spacing: 12) {
            SymbolBadge(symbol: "sparkles", tint: .cyan, diameter: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("You’re all set")
                    .font(.callout.weight(.semibold))
                Text("Existing icons start out in the Hidden section. Open the layout editor and drag the ones you use often back to Visible.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .glassEffect(.regular.tint(.cyan.opacity(0.12)), in: .rect(cornerRadius: 18))
    }
}

/// A label with the text first and the icon after it ("Open Layout Editor ->").
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon
                .font(.body.weight(.semibold))
        }
    }
}
