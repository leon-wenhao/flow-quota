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

/// Positive sectors retain every named process; no top-N truncation or
/// implicit source merging. Observed zero remains available in the details.
struct UsagePieData: Equatable {
    let slices: [UsagePieSlice]
    let totalBytes: Int64

    static func make(_ values: [UsageChartValue]) -> UsagePieData? {
        guard values.allSatisfy({ $0.bytes >= 0 }),
              let total = UsageFormatter.total(values.map(\.bytes)) else { return nil }
        let sorted = values.filter { $0.bytes > 0 }.sorted {
            $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes
        }
        let slices = sorted.map {
            UsagePieSlice(id: "item:" + $0.id, label: $0.label, bytes: $0.bytes)
        }
        return UsagePieData(slices: slices, totalBytes: total)
    }
}
