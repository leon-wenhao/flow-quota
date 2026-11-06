import Foundation

struct UsageChartValue: Identifiable, Equatable {
    let id: String
    let label: String
    let bytes: Int64
}

struct UsagePieSlice: Identifiable, Equatable {
    let id: String
    let label: String
    let bytes: Int64
}

/// Positive sectors only. The tail stays in the denominator as “其他应用” so
/// showing the largest five never implies they represent all attributed use.
struct UsagePieData: Equatable {
    let slices: [UsagePieSlice]
    let totalBytes: Int64

    static func make(_ values: [UsageChartValue], limit: Int = 5) -> UsagePieData? {
        guard values.allSatisfy({ $0.bytes >= 0 }),
              let total = UsageFormatter.total(values.map(\.bytes)) else { return nil }
        let sorted = values.filter { $0.bytes > 0 }.sorted {
            $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes
        }
        let count = max(1, limit)
        var slices = sorted.prefix(count).map {
            UsagePieSlice(id: "item:" + $0.id, label: $0.label, bytes: $0.bytes)
        }
        if sorted.count > count,
           let other = UsageFormatter.total(sorted.dropFirst(count).map(\.bytes)) {
            slices.append(UsagePieSlice(id: "remaining", label: "其他应用", bytes: other))
        }
        return UsagePieData(slices: slices, totalBytes: total)
    }
}
