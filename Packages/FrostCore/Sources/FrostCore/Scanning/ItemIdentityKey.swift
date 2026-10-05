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
///    share that text, the n-th of them (in AX order) gets `#n` appended (`desc:Weather#1`).
/// 3. Otherwise its index among the app's children: `idx:<n>` (stable as long as the app creates the same items).
///
/// The AX title is never used: for text items it is the text they show, which often changes (a timer, a percentage).
public enum ItemIdentityKey {
    public static func keys(for children: [AXItemAttributes]) -> [String] {
        let identifiers = children.map { normalized($0.identifier) }
        let identifierCounts = Dictionary(identifiers.compactMap { $0 }.map { ($0, 1) }, uniquingKeysWith: +)
        let bases: [String?] = children.indices.map { index in
            if let identifier = identifiers[index], identifierCounts[identifier] == 1 { return nil }
            if let description = normalized(children[index].description) { return "desc:" + description }
            if let help = normalized(children[index].help) { return "help:" + help }
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

    static func normalized(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
