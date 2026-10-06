import Foundation

/// The Privacy & Security panes Frost sends the user to. The scheme and anchors are the ones System Settings itself
/// uses ("Open in System Settings" links); opening one selects that pane and Frost's own row in it.
public enum PrivacySettingsPane: String, CaseIterable, Sendable {
    case accessibility = "Privacy_Accessibility"
    case screenRecording = "Privacy_ScreenCapture"

    public var url: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")
    }
}
