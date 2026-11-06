import Foundation
import FlowQuotaCore

extension QuotaStore {
    /// Same transaction as the corresponding daily delta. Baselines never call this.
    func addApplicationMinute(day: String, category: TrafficCategory,
                              increment: UsageIncrement, minute: Int64) throws {
        let key = increment.identity.key
        let previous = try database.query("""
            SELECT uploaded_bytes, downloaded_bytes, sample_count FROM application_usage_minutes
            WHERE day = ? AND category = ? AND minute_start_ms = ? AND app_key = ?
            """, [.text(day), .text(category.rawValue), .integer(minute), .text(key)]) {
                ($0.integer(0), $0.integer(1), $0.integer(2))
            }.first
        let upload = try checkedAdd(previous?.0 ?? 0, increment.uploadedBytes)
        let download = try checkedAdd(previous?.1 ?? 0, increment.downloadedBytes)
        let samples = try checkedAdd(previous?.2 ?? 0, 1)
        _ = try checkedAdd(upload, download)
        try database.execute("""
            INSERT INTO application_usage_minutes
              (day, category, minute_start_ms, app_key, uploaded_bytes, downloaded_bytes, sample_count)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(day, category, minute_start_ms, app_key) DO UPDATE SET
              uploaded_bytes = excluded.uploaded_bytes, downloaded_bytes = excluded.downloaded_bytes,
              sample_count = excluded.sample_count
            """, [.text(day), .text(category.rawValue), .integer(minute), .text(key),
                  .integer(upload), .integer(download), .integer(samples)])
    }

    /// Range reads are on demand, never included in the regular status snapshot.
    public func applicationTimeline(_ query: ApplicationTimelineQuery) throws -> ApplicationUsageTimeline {
        try ApplicationTimelineGrouping.make(query: query, rows: applicationTimelineRows(query))
    }

    /// Service-internal rows before display filtering/ranking, for merging session Clash minutes.
    /// This unranked result is never sent directly over IPC.
    public func applicationTimelineRows(_ query: ApplicationTimelineQuery) throws -> [ApplicationUsageBucket] {
        try StoreDay.validate(query.day)
        let dayStart = calendar.startOfDay(for: clock())
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart),
              query.day == (try StoreDay.label(at: clock(), calendar: calendar)),
              query.start >= dayStart, query.end <= dayEnd, query.end > query.start,
              query.end.timeIntervalSince(query.start) <= 90_000 else {
            throw StoreError.configuration("应用分时查询仅支持当天的有效时段")
        }
        if let appKey = query.appKey { try validateAppKey(appKey) }
        let start = try StoreDay.milliseconds(query.start)
        let end = try StoreDay.milliseconds(query.end)
        guard start % 60_000 == 0, end % 60_000 == 0 else {
            throw StoreError.configuration("应用分时查询须按分钟对齐")
        }
        let bucketMinutes = query.bucketMinutes
        let step = Int64(bucketMinutes) * 60_000
        var bindings: [SQLValue] = [.integer(start), .integer(step), .text(query.day),
                                      .text(query.category.rawValue), .integer(start), .integer(end)]
        let filter = query.appKey == nil ? "" : " AND m.app_key = ?"
        if let appKey = query.appKey { bindings.append(.text(appKey)) }
        let rows = try database.query("""
            SELECT m.app_key, a.name, (m.minute_start_ms - ?) / ? AS bucket,
                   SUM(m.uploaded_bytes), SUM(m.downloaded_bytes), SUM(m.sample_count)
            FROM application_usage_minutes m JOIN applications a ON a.app_key = m.app_key
            WHERE m.day = ? AND m.category = ? AND m.minute_start_ms >= ? AND m.minute_start_ms < ?
            \(filter)
            GROUP BY m.app_key, bucket ORDER BY bucket, m.app_key
            """, bindings) {
                ApplicationUsageBucket(appKey: $0.text(0), name: $0.text(1),
                    startMilliseconds: start + $0.integer(2) * step,
                    uploadedBytes: $0.integer(3), downloadedBytes: $0.integer(4), sampleCount: $0.integer(5))
            }
        return rows
    }
}
