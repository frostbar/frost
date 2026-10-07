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
    /// The system's Screen Recording prompt of that request is expected or still on screen
    /// (`PermissionsService.isScreenRecordingPromptPending`): the user hasn't decided yet, so the card waits instead of
    /// asking for a relaunch underneath the prompt.
    var screenRecordingPromptPending = false
    /// First run with existing icons in the Always Hidden section: once Accessibility is granted they are moved to the
    /// Hidden section automatically (see `NewItemPlacer`).
    var firstRunPlacementPending = false

    /// Everything works once Accessibility is granted; Screen Recording only adds real icon images
    /// (`PermissionCapabilities`).
    var isReady: Bool {
        PermissionCapabilities(accessibility: accessibility, screenRecording: screenRecording).canManageItems
    }
    /// Same rule as `PermissionsService.screenRecordingNeedsRelaunch` (About's row).
    var needsRelaunch: Bool { screenRecordingRequested && !screenRecording && !screenRecordingPromptPending }
    /// Requested, and the system prompt is expected or on screen.
    var isWaitingForScreenRecordingPrompt: Bool {
        screenRecordingRequested && !screenRecording && screenRecordingPromptPending
    }
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
    /// The content's height changed (a notice appearing or going, also every frame of its animation): the window
    /// follows it (`OnboardingWindowController`).
    var onHeightChange: @MainActor (CGFloat) -> Void = { _ in }

    var body: some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
    }

    private var content: some View {
        OnboardingView(state: state, actions: actions)
    }

    private var state: OnboardingState {
        let permissions = model.permissions
        var state = OnboardingState(accessibility: permissions.accessibility,
                                    screenRecording: permissions.screenRecording,
                                    screenRecordingRequested: permissions.screenRecordingRequested,
                                    firstRunPlacementPending: firstRunPlacementPending)
        state.screenRecordingPromptPending = permissions.isScreenRecordingPromptPending
        return state
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

    /// Width of the whole window. Its height is the content's (`OnboardingWindowController`), including the
    /// transparent title bar area the header extends under, so nothing is clipped whatever the system's fonts and
    /// metrics (macOS 27's are taller than 26's) or the notice shown.
    static let width: CGFloat = 520

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
                                       : state.isWaitingForScreenRecordingPrompt ? .waiting
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

            footer
                .padding(.top, 22)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .frame(width: Self.width)
        // As tall as the content: the window follows this height.
        .fixedSize(horizontal: false, vertical: true)
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
        /// Requested, and the system's prompt is expected or still on screen (Screen Recording): neither Grant Access
        /// (a second request) nor Needs Relaunch fits yet.
        case waiting
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
                } else if status == .waiting {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.blurReplace)
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
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: Text {
        switch status {
        case .granted: Text("Granted")
        case .needsRelaunch: Text("Needs Relaunch")
        case .waiting, .notGranted: Text("Not granted")
        }
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
