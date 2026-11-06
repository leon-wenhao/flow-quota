import Foundation

struct UsageTimeSlot: Identifiable, Equatable {
    var id: Date { start }
    let start: Date
    let end: Date
    var uploadedBytes: Int64 = 0
    var downloadedBytes: Int64 = 0
    var sampleCount: Int64 = 0
    var observedMinutes: Int = 0
    var totalBytes: Int64? { UsageFormatter.total([uploadedBytes, downloadedBytes]) }
}

/// Summary of the live application timeline. Empty slots carry sampleCount == 0
/// and must remain distinct from an observed zero-byte interval.
struct UsageTimelineData: Equatable {
    let slots: [UsageTimeSlot]
    let interval: DateInterval
    let bucketMinutes: Int
    let uploadedBytes: Int64?
    let downloadedBytes: Int64?
    var totalBytes: Int64? {
        guard let uploadedBytes, let downloadedBytes else { return nil }
        return UsageFormatter.total([uploadedBytes, downloadedBytes])
    }
}
