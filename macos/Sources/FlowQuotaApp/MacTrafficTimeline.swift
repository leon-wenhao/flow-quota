import Foundation
import FlowQuotaCore

/// The physical meter is authoritative and remains available when the process
/// query fails. It is never backfilled from application sums or Clash API totals.
enum MacTrafficTimeline {
    static func make(query: ApplicationTimelineQuery, minutes: [InterfaceUsageMinute]?) -> ApplicationTimelinePresentation? {
        guard let minutes, query.start.timeIntervalSince1970.isFinite,
              query.end.timeIntervalSince1970.isFinite, query.start.timeIntervalSince1970 >= 0,
              query.end.timeIntervalSince1970 < Double(Int64.max) / 1_000,
              query.end > query.start, query.end.timeIntervalSince(query.start) <= 90_000 else { return nil }
        let step = Int64(query.bucketMinutes) * 60_000
        let start = Int64(query.start.timeIntervalSince1970 * 1_000)
        let end = Int64(query.end.timeIntervalSince1970 * 1_000)
        guard start % 60_000 == 0, end % 60_000 == 0 else { return nil }
        var grouped: [Int64: ApplicationUsageBucket] = [:]
        var seen = Set<Int64>()
        for minute in minutes where minute.minuteStartMilliseconds >= start && minute.minuteStartMilliseconds < end {
            guard minute.minuteStartMilliseconds % 60_000 == 0,
                  minute.sampleCount > 0, seen.insert(minute.minuteStartMilliseconds).inserted else { return nil }
            let timestamp = start + (minute.minuteStartMilliseconds - start) / step * step
            let previous = grouped[timestamp]
            guard let upload = UsageFormatter.total([previous?.uploadedBytes ?? 0, minute.uploadedBytes]),
                  let download = UsageFormatter.total([previous?.downloadedBytes ?? 0, minute.downloadedBytes]),
                  let samples = UsageFormatter.total([previous?.sampleCount ?? 0, minute.sampleCount]),
                  UsageFormatter.total([upload, download]) != nil else { return nil }
            grouped[timestamp] = ApplicationUsageBucket(appKey: "meter:physical", name: "Mac 总流量",
                startMilliseconds: timestamp, uploadedBytes: upload, downloadedBytes: download, sampleCount: samples)
        }
        return ApplicationTimelinePresentation.make(ApplicationUsageTimeline(query: query,
            bucketMinutes: query.bucketMinutes, buckets: Array(grouped.values)))
    }
}
