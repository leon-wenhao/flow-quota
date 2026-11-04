import Foundation

/// SQLite BINARY keys compare UTF-8 bytes, while Swift strings use Unicode
/// canonical equivalence. Require one representation at every ledger boundary.
public enum AppKey {
    public static func isCanonical(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !value.utf8.contains(0)
            && value.utf8.elementsEqual(value.precomposedStringWithCanonicalMapping.utf8)
    }
}
