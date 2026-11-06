import Foundation
import FlowQuotaCore

/// Bounded, current-day session aggregates only. No hosts, addresses or connection IDs.
/// Continuous connection deltas arrive from the same accumulator as the application list.
struct MihomoMinuteHistory: Sendable {
    struct MinuteKey: Hashable, Sendable { let source: String; let minute: Int64 }
    private var day: String?
    private var minutes: [TrafficCategory: [MinuteKey: ApplicationUsageBucket]] = [:]
    private var limited: Set<TrafficCategory> = []
    private let maximumRows: Int

    init(maximumRows: Int = 32_768) { self.maximumRows = max(0, maximumRows) }

    mutating func reset() { day = nil; minutes = [:]; limited = [] }

    mutating func setDay(_ value: String) {
        guard day != value else { return }
        reset()
        day = value
    }

    mutating func record(source: MihomoProxySource, category: TrafficCategory, at date: Date,
                         upload: Int64, download: Int64) throws {
        let timestamp = floor(date.timeIntervalSince1970 / 60) * 60_000
        guard timestamp.isFinite, timestamp >= 0, timestamp < Double(Int64.max),
              upload >= 0, download >= 0 else { throw PlatformError.malformedReply }
        let minute = Int64(timestamp)
        let key = MinuteKey(source: source.id, minute: minute)
        let previous = minutes[category]?[key]
        guard previous != nil || (minutes[category]?.count ?? 0) < maximumRows else {
            limited.insert(category)
            return
        }
        let uploaded = try add(previous?.uploadedBytes ?? 0, upload)
        let downloaded = try add(previous?.downloadedBytes ?? 0, download)
        _ = try add(uploaded, downloaded)
        minutes[category, default: [:]][key] = ApplicationUsageBucket(appKey: nil,
            name: source.displayName, startMilliseconds: minute,
            uploadedBytes: uploaded, downloadedBytes: downloaded,
            sampleCount: try add(previous?.sampleCount ?? 0, 1), clashSourceID: source.id)
    }

    /// Query validation and bucket width are shared with the persistent minute query.
    func rows(for query: ApplicationTimelineQuery) throws -> [ApplicationUsageBucket] {
        guard query.day == day, query.appKey == nil else { return [] }
        let lower = query.start.timeIntervalSince1970 * 1_000
        let upper = query.end.timeIntervalSince1970 * 1_000
        guard lower.isFinite, upper.isFinite, lower >= 0, upper < Double(Int64.max),
              upper > lower, upper - lower <= 90_000_000,
              lower.truncatingRemainder(dividingBy: 60_000) == 0,
              upper.truncatingRemainder(dividingBy: 60_000) == 0 else { throw PlatformError.malformedReply }
        let start = Int64(lower)
        let end = Int64(upper)
        let step = Int64(query.bucketMinutes) * 60_000
        var rows: [MinuteKey: ApplicationUsageBucket] = [:]
        for row in minutes[query.category]?.values ?? Dictionary<MinuteKey, ApplicationUsageBucket>().values {
            guard row.startMilliseconds >= start, row.startMilliseconds < end,
                  let source = row.clashSourceID else { continue }
            let bucket = start + (row.startMilliseconds - start) / step * step
            let key = MinuteKey(source: source, minute: bucket)
            let previous = rows[key]
            rows[key] = ApplicationUsageBucket(appKey: nil, name: row.name, startMilliseconds: bucket,
                uploadedBytes: try add(previous?.uploadedBytes ?? 0, row.uploadedBytes),
                downloadedBytes: try add(previous?.downloadedBytes ?? 0, row.downloadedBytes),
                sampleCount: try add(previous?.sampleCount ?? 0, row.sampleCount), clashSourceID: source)
        }
        return Array(rows.values)
    }

    func notice(for category: TrafficCategory) -> String {
        let cap = limited.contains(category) ? " 来源分钟汇总已达容量上限，部分时段明细缺失。" : ""
        return "Clash 分时仅含本次服务运行后的有效观测；旧时段、暂停及故障间断不补算，重启清空。" + cap
    }

    private func add(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw PlatformError.unavailable("Clash 分时归因超出整数范围。") }
        return value
    }
}
