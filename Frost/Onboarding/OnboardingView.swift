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
    /// First run with existing icons in the Always Hidden section: once Accessibility is granted they are moved to the
    /// Hidden section automatically (see `NewItemPlacer`).
    var firstRunPlacementPending = false

    /// Everything works once Accessibility is granted; Screen Recording only adds real icon images
    /// (`PermissionCapabilities`).
    var isReady: Bool {
        PermissionCapabilities(accessibility: accessibility, screenRecording: screenRecording).canManageItems
    }
    var needsRelaunch: Bool { screenRecordingRequested && !screenRecording }
    /// Explains where existing icons are for now while Accessibility is missing and no relaunch is pending.
    var showsPlacementNote: Bool { firstRunPlacementPending && !isReady && !needsRelaunch }
}

/// Actions emitted by the onboarding view.
struct OnboardingActions {
    var grantAccessibility: @MainActor () -> Void
    var grantScreenRecording: @MainActor () -> Void
    /// Opens System Settings' Screen Recording pane (shown while a relaunch is pending, next to Relaunch).
    var openScreenRecordingSettings: @MainActor () -> Void
    var relaunch: @MainActor () -> Void
    /// Closes onboarding (Not Now / Done).
    var dismiss: @MainActor () -> Void
    /// Closes onboarding and opens the Layout tab of the settings window.
    var openLayoutEditor: @MainActor () -> Void
}

/// Root view of the onboarding window: reads permission state from `AppModel`.
struct OnboardingRootView: View {
    @Environment(AppModel.self) private var model
    let actions: OnboardingActions

    var body: some View {
        OnboardingView(state: OnboardingState(accessibility: model.permissions.accessibility,
                                              screenRecording: model.permissions.screenRecording,
                                              screenRecordingRequested: model.permissions.screenRecordingRequested,
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

            Text("Frost needs Accessibility; Screen Recording is optional.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.bottom, 10)

            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 12) {
                    PermissionCard(symbol: "accessibility", tint: .blue, title: "Accessibility", tag: "Required",
                                   detail: "Used to move icons between sections and to click icons in the Frost Bar.",
                                   status: state.accessibility ? .granted : .notGranted,
                                   grant: actions.grantAccessibility)
                    PermissionCard(symbol: "rectangle.dashed.badge.record", tint: .pink, title: "Screen Recording",
                                   tag: "Optional",
                                   detail: "Shows real images of icons. Without it, they appear as app icons. macOS shows a purple dot in the menu bar while Frost captures them.",
                                   status: state.screenRecording ? .granted
                                       : state.needsRelaunch ? .needsRelaunch : .notGranted,
                                   grant: actions.grantScreenRecording)
                }
            }

            ZStack {
                if state.needsRelaunch {
                    RelaunchNotice(openSettings: actions.openScreenRecordingSettings)
                        .transition(.blurReplace.combined(with: .move(edge: .top)))
                } else if state.isReady {
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
            if state.needsRelaunch {
                // The next step is the relaunch, so it is the default button whatever else is ready.
                Button(state.isReady ? "Done" : "Not Now", action: actions.dismiss)
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                Button("Relaunch", action: actions.relaunch)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } else if state.isReady {
                Button("Done", action: actions.dismiss)
                    .buttonStyle(.glass)
                    .controlSize(.large)
                Button(action: actions.openLayoutEditor) {
                    Label("Open Layout Editor", systemImage: "arrow.right")
                        .labelStyle(TrailingIconLabelStyle())
                }
                .buttonStyle(.borderedProminent)
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
    /// "Required" / "Optional", shown next to the title.
    let tag: LocalizedStringKey
    let detail: LocalizedStringKey
    enum Status {
        case notGranted
        /// Requested, but it takes effect only after a relaunch (Screen Recording).
        case needsRelaunch
        case granted
    }

    let status: Status
    let grant: () -> Void
    private var isGranted: Bool { status == .granted }

    var body: some View {
        HStack(spacing: 14) {
            SymbolBadge(symbol: symbol, tint: tint, diameter: 42)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                    Text(tag)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: .capsule)
                }
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
                } else if status == .needsRelaunch {
                    Label("Needs Relaunch", systemImage: "arrow.clockwise")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                        .transition(.blurReplace)
                } else {
                    Button("Grant Access", action: grant)
                        .buttonStyle(.borderedProminent)
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
        .accessibilityValue(isGranted ? Text("Granted") : status == .needsRelaunch ? Text("Needs Relaunch")
                                                                                  : Text("Not granted"))
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

/// After requesting Screen Recording: Frost must be relaunched for it to take effect. A user who denied the prompt
/// (or closed it without flipping the switch) still has to turn it on first, so the card also opens the pane — the
/// footer's Relaunch stays the primary action.
private struct RelaunchNotice: View {
    let openSettings: () -> Void

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
                Button("Open System Settings", action: openSettings)
                    .buttonStyle(.link)
                    .font(.footnote)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
            Text("Existing icons stay in Always Hidden until Accessibility is granted, then move to Hidden automatically.")
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

/// Once Accessibility is granted: explains that existing icons start out in the Hidden section and points the user to
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
