/// How one "Grant Access" click is carried out. macOS lists an app under Privacy & Security only after the app has
/// asked once through the system API, and that ask shows a system prompt whose own "Open System Settings" button leads
/// the user there. Doing both at once (the prompt and opening the pane ourselves) leaves the prompt behind System
/// Settings, where it resurfaces after the user already granted. So the first request per permission only asks (the
/// prompt takes the user to Settings), and later ones, once the app is listed, open the pane directly with no prompt.
public enum PermissionRequest: Equatable, Sendable {
    /// Ask through the system API (it shows its prompt); nothing else.
    case systemPrompt
    /// Open the Privacy & Security pane directly.
    case openSettings

    /// `alreadyAsked`: Frost asked for this permission before (recorded when it did).
    public static func step(alreadyAsked: Bool) -> PermissionRequest {
        alreadyAsked ? .openSettings : .systemPrompt
    }
}
