import Foundation
import FlowQuotaCore

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

/// Presentation aggregation only. No row is invented for a missing observation;
/// empty slots carry sampleCount == 0, and the view must render them as unknown.
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

    static func make(minutes: [InterfaceUsageMinute], start: Date, end: Date) -> UsageTimelineData? {
        let lower = floor(start.timeIntervalSince1970 / 60) * 60
        let upper = ceil(end.timeIntervalSince1970 / 60) * 60
        guard lower.isFinite, upper.isFinite, upper > lower, upper - lower <= 172_800 else { return nil }
        let bucketMinutes = upper - lower <= 3_660 ? 5 : 30
        let step = Double(bucketMinutes * 60)
        let count = Int(ceil((upper - lower) / step))
        var slots = (0..<count).map { index in
            UsageTimeSlot(start: Date(timeIntervalSince1970: lower + Double(index) * step),
                          end: Date(timeIntervalSince1970: min(upper, lower + Double(index + 1) * step)))
        }
        var seen = Set<Int64>()
        for minute in minutes {
            let time = Double(minute.minuteStartMilliseconds) / 1_000
            guard time >= lower, time < upper else { continue }
            guard minute.minuteStartMilliseconds > 0, minute.minuteStartMilliseconds % 60_000 == 0,
                  minute.sampleCount > 0, minute.uploadedBytes >= 0, minute.downloadedBytes >= 0,
                  seen.insert(minute.id).inserted else { return nil }
            let index = Int((time - lower) / step)
            guard let upload = UsageFormatter.total([slots[index].uploadedBytes, minute.uploadedBytes]),
                  let download = UsageFormatter.total([slots[index].downloadedBytes, minute.downloadedBytes]),
                  let samples = UsageFormatter.total([slots[index].sampleCount, minute.sampleCount]),
                  UsageFormatter.total([upload, download]) != nil else { return nil }
            slots[index].uploadedBytes = upload
            slots[index].downloadedBytes = download
            slots[index].sampleCount = samples
            slots[index].observedMinutes += 1
        }
        let observed = slots.filter { $0.sampleCount > 0 }
        let upload = observed.isEmpty ? nil : UsageFormatter.total(observed.map(\.uploadedBytes))
        let download = observed.isEmpty ? nil : UsageFormatter.total(observed.map(\.downloadedBytes))
        if !observed.isEmpty {
            guard let upload, let download, UsageFormatter.total([upload, download]) != nil else { return nil }
        }
        return UsageTimelineData(slots: slots, interval: DateInterval(
            start: Date(timeIntervalSince1970: lower), end: Date(timeIntervalSince1970: upper)),
            bucketMinutes: bucketMinutes, uploadedBytes: upload, downloadedBytes: download)
    }

    func slot(at date: Date) -> UsageTimeSlot? {
        slots.first { $0.start <= date && date < $0.end }
    }
}
