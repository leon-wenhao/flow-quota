import Foundation
import FlowQuotaCore

extension QuotaStore {
    public func sourceTimeline(_ query: ApplicationTimelineQuery) throws -> ApplicationUsageTimeline {
        let raw = try applicationTimelineRows(query, bucketMinutes: 1)
        let start = try StoreDay.milliseconds(query.start)
        let end = try StoreDay.milliseconds(query.end)
        // A single-application request remains raw evidence for its rule/details.
        let children = query.appKey == nil ? try clashMinuteRows(day: query.day, category: query.category, start: start, end: end) : []
        let result = query.appKey == nil ? try ClashMinuteBreakdown.resolve(processes: raw, sources: children) : (rows: raw, notice: nil)
        let grouped = try ClashMinuteBreakdown.group(result.rows, start: start, step: Int64(query.bucketMinutes) * 60_000)
        let timeline = try ApplicationTimelineGrouping.make(query: query, rows: grouped, clashNotice: result.notice)
        return ApplicationUsageTimeline(query: query, bucketMinutes: timeline.bucketMinutes,
            buckets: timeline.buckets, clashNotice: timeline.clashNotice, sourcesResolved: true)
    }

    /// Only known, accepted minute sources are deducted from today's parent.
    /// Legacy parent bytes with no minute evidence remain unknown, never backfilled.
    public func dailyClashBreakdown(day: String, category: TrafficCategory) throws -> ClashUsageBreakdown? {
        let apps = try snapshot(day: day, category: category).filter { ClashUsageBreakdown.isProxy($0.identity) }
        guard !apps.isEmpty, try hasApplicationUsage(day: day, category: category) else { return nil }
        let keys = Set(try database.query("SELECT app_key FROM daily_usage WHERE day = ? AND category = ?",
            [.text(day), .text(category.rawValue)]) { $0.text(0) })
        guard apps.contains(where: { keys.contains($0.id) }) else { return nil }
        let upload = try apps.reduce(Int64(0)) { try checkedAdd($0, $1.usage.uploadedBytes) }
        let download = try apps.reduce(Int64(0)) { try checkedAdd($0, $1.usage.downloadedBytes) }
        let start = calendar.startOfDay(for: clock())
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { throw ClashBreakdownError.invalid }
        let query = ApplicationTimelineQuery(day: day, category: category, start: start, end: end, appKey: apps.count == 1 ? apps[0].id : nil)
        let raw = try applicationTimelineRows(query, bucketMinutes: 1).filter {
            $0.appKey.map { ClashUsageBreakdown.isProxy(AppIdentity(key: $0, name: $0)) } ?? false
        }
        let result = try ClashMinuteBreakdown.resolve(processes: raw, sources: clashMinuteRows(day: day, category: category))
        let accepted = result.rows.compactMap { row -> ClashUsageSource? in
            guard let id = row.clashSourceID, id != ClashUsageBreakdown.unknownID else { return nil }
            return ClashUsageSource(id: id, name: row.name, uploadedBytes: row.uploadedBytes, downloadedBytes: row.downloadedBytes)
        }
        let breakdown = try ClashUsageBreakdown.split(upload: upload, download: download,
            sources: apps.count == 1 ? accepted : [])
        return ClashUsageBreakdown(sources: breakdown.sources, notice: result.notice ?? breakdown.notice)
    }
}
