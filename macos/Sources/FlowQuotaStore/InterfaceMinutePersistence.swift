import Foundation
import FlowQuotaCore

extension QuotaStore {
    /// Ordered current-day minute summaries. Never derives a time series from
    /// daily totals or application attribution. Empty means no observed interval.
    public func interfaceUsageMinutes(day: String, category: TrafficCategory) throws -> [InterfaceUsageMinute] {
        try StoreDay.validate(day)
        return try database.query("""
            SELECT minute_start_ms, uploaded_bytes, downloaded_bytes, sample_count
            FROM interface_usage_minutes WHERE day = ? AND category = ? ORDER BY minute_start_ms
            """, [.text(day), .text(category.rawValue)]) {
                InterfaceUsageMinute(minuteStartMilliseconds: $0.integer(0), uploadedBytes: $0.integer(1),
                                     downloadedBytes: $0.integer(2), sampleCount: $0.integer(3))
            }
    }

    /// Called only inside recordSample's transaction for a continuous measured
    /// interface delta. Baselines must omit observedAt. Assigns the entire delta
    /// to the ending minute; never interpolates bytes across a minute boundary.
    func addInterfaceMinute(day: String, category: TrafficCategory,
                            increment: InterfaceUsage, observedAt: Date) throws {
        guard try StoreDay.label(at: observedAt, calendar: calendar) == day else {
            throw StoreError.configuration("Interface observation day must match batch day")
        }
        let timestamp = try StoreDay.milliseconds(observedAt)
        let minute = timestamp / 60_000 * 60_000
        let previous = try database.query("""
            SELECT uploaded_bytes, downloaded_bytes, sample_count FROM interface_usage_minutes
            WHERE day = ? AND category = ? AND minute_start_ms = ?
            """, [.text(day), .text(category.rawValue), .integer(minute)]) {
                ($0.integer(0), $0.integer(1), $0.integer(2))
            }.first
        let upload = try checkedAdd(previous?.0 ?? 0, increment.uploadedBytes)
        let download = try checkedAdd(previous?.1 ?? 0, increment.downloadedBytes)
        let samples = try checkedAdd(previous?.2 ?? 0, 1)
        _ = try checkedAdd(upload, download)
        try database.execute("""
            INSERT INTO interface_usage_minutes
              (day, category, minute_start_ms, uploaded_bytes, downloaded_bytes, sample_count)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(day, category, minute_start_ms) DO UPDATE SET
              uploaded_bytes = excluded.uploaded_bytes, downloaded_bytes = excluded.downloaded_bytes,
              sample_count = excluded.sample_count
            """, [.text(day), .text(category.rawValue), .integer(minute),
                  .integer(upload), .integer(download), .integer(samples)])
    }
}
