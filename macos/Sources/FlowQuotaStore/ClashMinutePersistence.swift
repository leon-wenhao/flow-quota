import Foundation
import FlowQuotaCore

extension QuotaStore {
    /// One API frame, in one transaction. Failed frames are never replayed from
    /// session totals; the caller resets continuity and the parent retains bytes.
    public func recordClashSources(_ sources: [ClashUsageSource], at date: Date, category: TrafficCategory) throws {
        let day = try StoreDay.label(at: date, calendar: calendar)
        guard day == (try StoreDay.label(at: clock(), calendar: calendar)), sources.count <= 128,
              Set(sources.map(\.id)).count == sources.count else {
            throw StoreError.configuration("Clash 来源批次日期或容量无效")
        }
        let ms = try StoreDay.milliseconds(date)
        let minute = ms / 60_000 * 60_000
        for source in sources { try source.validate() }
        guard !sources.isEmpty else { return }
        try database.transaction {
            let bindings: [SQLValue] = [.text(day), .text(category.rawValue)]
            let known = Set(try database.query("""
                SELECT DISTINCT source_id FROM clash_source_usage_minutes WHERE day = ? AND category = ?
                """, bindings) { $0.text(0) })
            guard known.union(sources.map(\.id)).count <= 128 else {
                throw StoreError.configuration("Clash 当日来源达到 128 项上限；未保存用量保留为其他未识别")
            }
            let count = try database.scalar("SELECT COUNT(*) FROM clash_source_usage_minutes WHERE day = ? AND category = ?", bindings)
            var added: Int64 = 0
            for source in sources {
                let key = bindings + [.integer(minute), .text(source.id)]
                let old = try database.query("""
                    SELECT name, identified, uploaded_bytes, downloaded_bytes, sample_count
                    FROM clash_source_usage_minutes WHERE day = ? AND category = ? AND minute_start_ms = ? AND source_id = ?
                    """, key) { ($0.text(0), $0.integer(1), $0.integer(2), $0.integer(3), $0.integer(4)) }.first
                guard old == nil || (old?.0 == source.name && old?.1 == (source.identified ? 1 : 0)) else {
                    throw StoreError.configuration("Clash 来源身份冲突")
                }
                if old == nil { added += 1 }
                guard count + added <= 32_768 else { throw StoreError.configuration("Clash 来源分钟记录达到容量上限") }
                let upload = try checkedAdd(old?.2 ?? 0, source.uploadedBytes)
                let download = try checkedAdd(old?.3 ?? 0, source.downloadedBytes)
                _ = try checkedAdd(upload, download)
                let samples = try checkedAdd(old?.4 ?? 0, 1)
                try database.execute("""
                    INSERT INTO clash_source_usage_minutes
                      (day, category, minute_start_ms, source_id, name, identified, uploaded_bytes, downloaded_bytes, sample_count)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(day, category, minute_start_ms, source_id) DO UPDATE SET
                      uploaded_bytes = excluded.uploaded_bytes, downloaded_bytes = excluded.downloaded_bytes,
                      sample_count = excluded.sample_count
                    """, key + [.text(source.name), .integer(source.identified ? 1 : 0),
                        .integer(upload), .integer(download), .integer(samples)])
            }
        }
    }

    public func dailyClashObservations(day: String, category: TrafficCategory) throws -> [ClashUsageSource] {
        try ClashUsageBreakdown.aggregate(clashMinuteRows(day: day, category: category).map(\.source))
    }

    public func clashMinuteRows(day: String, category: TrafficCategory, start: Int64 = 0, end: Int64 = .max) throws -> [ClashMinuteUsage] {
        try StoreDay.validate(day)
        return try database.query("""
            SELECT minute_start_ms, source_id, name, identified, uploaded_bytes, downloaded_bytes
            FROM clash_source_usage_minutes
            WHERE day = ? AND category = ? AND minute_start_ms >= ? AND minute_start_ms < ?
            ORDER BY minute_start_ms, source_id
            """, [.text(day), .text(category.rawValue), .integer(start), .integer(end)]) {
                ClashMinuteUsage(minute: $0.integer(0), source: ClashUsageSource(id: $0.text(1), name: $0.text(2),
                    uploadedBytes: $0.integer(4), downloadedBytes: $0.integer(5), identified: $0.integer(3) == 1))
            }
    }
}
