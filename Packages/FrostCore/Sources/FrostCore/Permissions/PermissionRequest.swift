/// How one "Grant Access" click is carried out. macOS lists an app under Privacy & Security only after the app asked
/// through the system API, and that ask shows a system prompt whose own "Open System Settings" button leads the user
/// there. Opening the pane ourselves as well leaves the prompt behind System Settings, where it resurfaces after the
/// user already granted. Measured in the VM (macOS 26):
///
/// - Accessibility (`AXIsProcessTrustedWithOptions` with the prompt option) shows its prompt on **every** call, also
///   when the app is listed and denied. So it is the whole request: Frost never opens the pane itself, and the app is
///   always listed whenever the user lands there.
/// - Screen Recording (`CGRequestScreenCaptureAccess`) prompts only for the first request of a process, and only while
///   the permission has no entry; otherwise it is silent. A silent call means the app is already listed, so the pane
///   is opened. Whether the prompt appeared is read from the window list (`promptVisible(baseline:current:)`): wait up
///   to `promptTimeout` for it, then open the pane.
public enum PermissionRequest {
    /// How long to wait for the system prompt after the Screen Recording request before concluding it was silent.
    public static let promptTimeout: Duration = .seconds(2)

    public enum Decision: Equatable, Sendable {
        case keepWaiting
        /// The prompt is up: it takes the user to Settings itself.
        case promptShown
        /// No prompt appeared: open the Settings pane directly.
        case openSettings
    }

    /// `elapsed` since the request; `promptVisible`: a prompt window is on screen.
    public static func decide(elapsed: Duration, promptVisible: Bool) -> Decision {
        if promptVisible { return .promptShown }
        return elapsed >= promptTimeout ? .openSettings : .keepWaiting
    }

    /// Owner names the system's permission prompt has used. Measured in the VM (macOS 26): the prompt is a window of
    /// `universalAccessAuthWarn` ("Screen Recording" / "Accessibility Access"). A window of one of these processes is
    /// the prompt; `promptVisible(baseline:current:)` adds a fallback for a renamed process.
    public static let promptOwnerNames: Set<String> = ["universalAccessAuthWarn"]

    /// Whether the prompt is one of the windows of this owner (the name rule on its own; the fallback needs the
    /// window list, see `promptVisible(baseline:current:)`).
    public static func isPromptWindow(ownerName: String?) -> Bool {
        guard let ownerName else { return false }
        return promptOwnerNames.contains(ownerName)
    }
}
