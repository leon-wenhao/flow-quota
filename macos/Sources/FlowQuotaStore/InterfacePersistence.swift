import FlowQuotaCore

extension QuotaStore {
    /// Persisted observed interface bytes for exactly this day. Nil means no
    /// sample has been recorded; a valid zero sample returns a zero-valued row.
    /// Does not infer freshness or reconstruct totals from application attribution.
    public func interfaceUsage(day: String, category: TrafficCategory = .metered) throws -> InterfaceUsage? {
        try StoreDay.validate(day)
        return try database.query("""
            SELECT uploaded_bytes, downloaded_bytes FROM daily_interface_usage WHERE day = ? AND category = ?
            """, [.text(day), .text(category.rawValue)]) {
                InterfaceUsage(day: day, uploadedBytes: $0.integer(0), downloadedBytes: $0.integer(1))
            }.first
    }

    // Caller owns the recordSample transaction. Checked Swift arithmetic avoids
    // SQLite's overflow promotion to REAL and keeps errors consistent with apps.
    func addInterfaceUsage(day: String, increment: InterfaceUsage, category: TrafficCategory = .metered) throws {
        try StoreDay.validate(increment.day)
        guard increment.day == day else {
            throw StoreError.configuration("Interface sample day must match batch day")
        }
        _ = try validateDeltas(increment.uploadedBytes, increment.downloadedBytes)
        let current = try interfaceUsage(day: day, category: category)
        let upload = try checkedAdd(current?.uploadedBytes ?? 0, increment.uploadedBytes)
        let download = try checkedAdd(current?.downloadedBytes ?? 0, increment.downloadedBytes)
        _ = try checkedAdd(upload, download)
        try database.execute("""
            INSERT INTO daily_interface_usage(day, uploaded_bytes, downloaded_bytes, category) VALUES (?, ?, ?, ?)
            ON CONFLICT(day, category) DO UPDATE SET uploaded_bytes = excluded.uploaded_bytes,
              downloaded_bytes = excluded.downloaded_bytes
            """, [.text(day), .integer(upload), .integer(download), .text(category.rawValue)])
    }
}
