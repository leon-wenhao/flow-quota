import FlowQuotaCore

/// Keep identities in place during polling. Usage sorting is an explicit user action.
struct ApplicationListOrder {
    private(set) var keys: [String] = []

    mutating func reconcile<T: Identifiable>(_ ranked: [T]) where T.ID == String {
        let present = Set(ranked.map(\.id))
        keys.removeAll { !present.contains($0) }
        var existing = Set(keys)
        for app in ranked where existing.insert(app.id).inserted { keys.append(app.id) }
    }

    mutating func sortByUsage<T: Identifiable>(_ ranked: [T]) where T.ID == String { keys = ranked.map(\.id) }

    func ordered<T: Identifiable>(_ ranked: [T]) -> [T] where T.ID == String {
        let values = Dictionary(ranked.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let existing = Set(keys)
        return keys.compactMap { values[$0] } + ranked.filter { !existing.contains($0.id) }
    }
}
