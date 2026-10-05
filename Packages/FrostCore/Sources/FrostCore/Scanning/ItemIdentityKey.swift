import Foundation

/// The AX attributes of one menu bar extra that identify it (read by `AXExtrasReader`).
public struct AXItemAttributes: Equatable, Sendable {
    public var identifier: String?
    public var description: String?
    public var help: String?

    public init(identifier: String? = nil, description: String? = nil, help: String? = nil) {
        self.identifier = identifier
        self.description = description
        self.help = help
    }
}

/// Derives the `ItemIdentity` key of each of one app's menu bar extras from their AX attributes, which need only
/// Accessibility (window titles need Screen Recording).
///
/// `children` are the app's extras in AX order, which is the order the app created them in (not their position in the
/// menu bar, which the user changes), including zero-size children. Rules, per child:
/// 1. A non-empty AX identifier no other child of the app has: `id:<identifier>` (system items have one).
/// 2. Otherwise its AX description, else its AX help (tooltip): `desc:<text>` / `help:<text>`; when several children
///    share that text, the n-th of them (in AX order) gets `#n` appended (`desc:Weather#1`). The text is escaped
///    (`\` -> `\\`, `#` -> `\#`), so an unescaped `#` is always the occurrence suffix: a literal description
///    `Status#0` (`desc:Status\#0`) never collides with the first of two `Status` children (`desc:Status#0`).
/// 3. Otherwise its index among the app's children: `idx:<n>` (stable as long as the app creates the same items).
///
/// The AX title is never used: for text items it is the text they show, which often changes (a timer, a percentage).
public enum ItemIdentityKey {
    public static func keys(for children: [AXItemAttributes]) -> [String] {
        let identifiers = children.map { normalized($0.identifier) }
        let identifierCounts = Dictionary(identifiers.compactMap { $0 }.map { ($0, 1) }, uniquingKeysWith: +)
        let bases: [String?] = children.indices.map { index in
            if let identifier = identifiers[index], identifierCounts[identifier] == 1 { return nil }
            if let description = normalized(children[index].description) { return "desc:" + escaped(description) }
            if let help = normalized(children[index].help) { return "help:" + escaped(help) }
            return nil
        }
        let baseCounts = Dictionary(bases.compactMap { $0 }.map { ($0, 1) }, uniquingKeysWith: +)
        var seen: [String: Int] = [:]
        return children.indices.map { index in
            if let identifier = identifiers[index], identifierCounts[identifier] == 1 { return "id:" + identifier }
            guard let base = bases[index] else { return "idx:\(index)" }
            guard baseCounts[base, default: 0] > 1 else { return base }
            let occurrence = seen[base, default: 0]
            seen[base] = occurrence + 1
            return "\(base)#\(occurrence)"
        }
    }

    /// The key text with the occurrence suffix's marker escaped (see the type's documentation).
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "#", with: "\\#")
    }

    /// The key an earlier (unreleased) encoding gave the same item, which appended the occurrence suffix to the text
    /// without escaping it; nil when it is the same key. `IdentityMigration` maps remembered state still stored under
    /// it.
    public static func unescapedEncoding(of key: String) -> String? {
        guard key.hasPrefix("desc:") || key.hasPrefix("help:"), key.contains("\\") else { return nil }
        var result = ""
        var escaping = false
        for character in key {
            if escaping {
                result.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result == key ? nil : result
    }

    static func normalized(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
