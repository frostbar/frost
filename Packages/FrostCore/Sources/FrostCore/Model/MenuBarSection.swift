public enum MenuBarSection: String, CaseIterable, Codable, Sendable {
    case visible, hidden, alwaysHidden

    /// Left-to-right order in the menu bar.
    public static let leftToRight: [MenuBarSection] = [.alwaysHidden, .hidden, .visible]
}
