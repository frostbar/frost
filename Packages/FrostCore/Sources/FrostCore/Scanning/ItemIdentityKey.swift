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
///    Every number in the text is replaced with `<n>` first (`normalizingNumbers`): some apps put live readings in
///    their description or tooltip (fan speeds, temperatures, percentages), and the key must not change with them.
///    Children whose texts differ only in numbers (`Fan 1`, `Fan 2`) therefore share a text and are told apart by the
///    occurrence suffix, i.e. by their order among the app's extras (creation order), like any other shared text.
/// 3. Otherwise its index among the app's children: `idx:<n>` (stable as long as the app creates the same items).
///
/// The AX title is never used: for text items it is the text they show, which often changes (a timer, a percentage).
/// AX identifiers are used as they are (numbers included): they are fixed names, not text shown to the user.
public enum ItemIdentityKey {
    public static func keys(for children: [AXItemAttributes]) -> [String] {
        keys(for: children, normalizingNumbers: true)
    }

    /// The keys versions before numbers were normalized gave the same children (numbers kept as they are), so that
    /// state remembered under them can be mapped to the current keys (`IdentityMigration`).
    public static func numberedKeys(for children: [AXItemAttributes]) -> [String] {
        keys(for: children, normalizingNumbers: false)
    }

    static func keys(for children: [AXItemAttributes], normalizingNumbers: Bool) -> [String] {
        let identifiers = children.map { normalized($0.identifier) }
        let identifierCounts = Dictionary(identifiers.compactMap { $0 }.map { ($0, 1) }, uniquingKeysWith: +)
        func text(_ value: String?) -> String? {
            guard let value = normalized(value) else { return nil }
            return escaped(normalizingNumbers ? self.normalizingNumbers(value) : value)
        }
        let bases: [String?] = children.indices.map { index in
            if let identifier = identifiers[index], identifierCounts[identifier] == 1 { return nil }
            if let description = text(children[index].description) { return "desc:" + description }
            if let help = text(children[index].help) { return "help:" + help }
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

    /// Replaces every number in `text` with `numberPlaceholder`. A number is a run of decimal digits (any script),
    /// with digit groups joined by `.`, `,`, `:`, an apostrophe or a non-breaking / narrow space (`4,990`, `4.9`,
    /// `12:30`, `4 990`) counted as one, and a leading sign (`-`, `+`, `−`) when it directly precedes the digits and
    /// doesn't follow a letter or digit (`-3` is a number; the dash in `v2-3` and in `side - 5` is not).
    public static func normalizingNumbers(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        var index = 0
        func isDigit(_ position: Int) -> Bool {
            guard position < characters.count, characters[position].unicodeScalars.count == 1,
                  let scalar = characters[position].unicodeScalars.first else { return false }
            return scalar.properties.numericType == .decimal
        }
        while index < characters.count {
            var start = index
            if signs.contains(characters[index]), isDigit(index + 1),
               index == 0 || !(characters[index - 1].isLetter || characters[index - 1].isNumber) {
                start = index + 1
            }
            guard isDigit(start) else {
                result.append(characters[index])
                index += 1
                continue
            }
            index = start
            while isDigit(index) { index += 1 }
            while index < characters.count, groupSeparators.contains(characters[index]), isDigit(index + 1) {
                index += 1
                while isDigit(index) { index += 1 }
            }
            result += numberPlaceholder
        }
        return result
    }

    /// What every number in a description or help text becomes in its key.
    public static let numberPlaceholder = "<n>"
    private static let signs: Set<Character> = ["-", "+", "\u{2212}"]
    private static let groupSeparators: Set<Character> = [".", ",", ":", "'", "\u{2019}", "\u{00A0}", "\u{202F}",
                                                           "\u{2009}"]

    /// A stored `desc:` / `help:` key with the numbers in its text normalized the way `keys` now does (the occurrence
    /// suffix, if any, is kept as it is); nil when that changes nothing. Lets state remembered under a key that
    /// contained live numbers follow the item (`IdentityMigration`).
    public static func numberNormalizedEncoding(of key: String) -> String? {
        guard key.hasPrefix("desc:") || key.hasPrefix("help:") else { return nil }
        // The text ends at the last unescaped `#` (the occurrence suffix).
        var suffixStart = key.endIndex
        var escaping = false
        for index in key.indices {
            if escaping {
                escaping = false
            } else if key[index] == "\\" {
                escaping = true
            } else if key[index] == "#" {
                suffixStart = index
            }
        }
        let text = key[..<suffixStart]
        // Digits, signs and separators are never escaped, so the escaped text can be normalized directly.
        let result = normalizingNumbers(String(text)) + key[suffixStart...]
        return result == key ? nil : result
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
