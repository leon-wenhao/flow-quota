import Foundation
import FlowQuotaCore

/// Service-owned ledger for observed usage, reminder receipts, and legacy budgets.
/// One actor owns the connection; callers submit batches, never write per packet.
public actor QuotaStore {
    let database: SQLiteConnection
    let clock: @Sendable () -> Date
    private let calendarOverride: Calendar?
    var calendar: Calendar {
        if let calendarOverride { return calendarOverride }
        var current = Calendar(identifier: .gregorian)
        current.timeZone = .current
        return current
    }

    /// Opens/creates a local SQLite file and commits versioned migrations before return.
    /// Parent directory/permissions belong to the owning service. Throws on any
    /// durability, foreign-key, migration, locking, or filesystem failure.
    public init(path: String) throws {
        let connection = try SQLiteConnection(path: path)
        try StoreSchema.migrate(connection)
        database = connection
        clock = { Date() }
        calendarOverride = nil
    }

    // Deterministic clock for tests; production callers cannot select a historical day.
    init(path: String, clock: @escaping @Sendable () -> Date, calendar: Calendar) throws {
        let connection = try SQLiteConnection(path: path)
        try StoreSchema.migrate(connection)
        database = connection
        self.clock = clock
        self.calendarOverride = calendar
    }

    /// Idempotent close; all later database operations fail with StoreError.closed.
    public func close() throws { try database.close() }

    /// Upserts only the display name, preserving all identity-linked state.
    public func registerApplication(_ identity: AppIdentity) throws {
        try validateAppKey(identity.key)
        try validateIdentifier(identity.name)
        try database.execute("""
            INSERT INTO applications(app_key, name) VALUES (?, ?)
            ON CONFLICT(app_key) DO UPDATE SET name = excluded.name
            """, [.text(identity.key), .text(identity.name)])
    }

    /// Exact retries succeed; versions must increase for any content change.
    public func saveRule(appKey: String, rule: QuotaRule, category: TrafficCategory = .metered) throws {
        try validateAppKey(appKey)
        try database.transaction {
            try requireApplication(appKey)
            if let previous = try ruleForApp(appKey, category: category) {
                if previous == rule { return }
                guard rule.version > previous.version else { throw StoreError.staleRuleVersion }
            }
            try database.execute("""
                INSERT INTO quota_rules(app_key, limit_bytes, warning_percent, version, category) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(app_key, category) DO UPDATE SET limit_bytes = excluded.limit_bytes,
                  warning_percent = excluded.warning_percent, version = excluded.version
                """, [.text(appKey), .optional(rule.limitBytes), .integer(Int64(rule.warningPercent)),
                      .integer(rule.version), .text(category.rawValue)])
        }
    }

    public func loadRules(category: TrafficCategory = .metered) throws -> [String: QuotaRule] {
        let rows = try database.query("SELECT app_key, limit_bytes, warning_percent, version FROM quota_rules WHERE category = ?", [.text(category.rawValue)]) {
            ($0.text(0), try Self.readRule($0, offset: 1))
        }
        var rules: [String: QuotaRule] = [:]
        for (key, rule) in rows {
            try validateAppKey(key)
            guard rules.updateValue(rule, forKey: key) == nil else {
                throw StoreError.configuration("Duplicate canonical app identities require explicit data repair")
            }
        }
        return rules
    }

    /// Actual settled/recorded bytes only. Query budgetBalance for unknown liabilities.
    public func snapshot(day: String, category: TrafficCategory = .metered) throws -> [ApplicationSnapshot] {
        try StoreDay.validate(day)
        return try database.query("""
            SELECT a.app_key, a.name, r.limit_bytes, r.warning_percent, r.version,
                   COALESCE(u.uploaded_bytes, 0), COALESCE(u.downloaded_bytes, 0)
            FROM applications a LEFT JOIN quota_rules r ON r.app_key = a.app_key AND r.category = ?
            LEFT JOIN daily_usage u ON u.app_key = a.app_key AND u.day = ? AND u.category = ?
            ORDER BY a.app_key
            """, [.text(category.rawValue), .text(day), .text(category.rawValue)]) { row in
                ApplicationSnapshot(identity: AppIdentity(key: row.text(0), name: row.text(1)),
                    rule: try row.optionalInteger(4).map { _ in try Self.readRule(row, offset: 2) },
                    usage: DailyUsage(appKey: row.text(0), day: day,
                                      uploadedBytes: row.integer(5), downloadedBytes: row.integer(6)))
            }
    }

    /// Additive measured traffic outside the lease path; never double-submit lease
    /// bytes here. Over-limit reality is retained. Negative/overflowing deltas fail.
    public func recordUsage(appKey: String, day: String, uploadedBytes: Int64,
                            downloadedBytes: Int64) throws {
        try validateAppKey(appKey)
        try StoreDay.validate(day)
        let delta = try validateDeltas(uploadedBytes, downloadedBytes)
        try database.transaction {
            try requireApplication(appKey)
            _ = try checkedAdd(balance(appKey: appKey, day: day).chargedBytes, delta)
            try addUsage(appKey: appKey, day: day, upload: uploadedBytes, download: downloadedBytes)
        }
    }

    /// Records the caller's acknowledgment after successful OS notification scheduling;
    /// returns true only for the first receipt. This does not prove visible delivery.
    /// A crash before acknowledgment may retry scheduling with the same OS identifier.
    /// Legacy `.blocked` records a reached threshold, not connection blocking.
    public func claimNotification(appKey: String, day: String, kind: NotificationKind,
                                  ruleVersion: Int64, category: TrafficCategory = .metered) throws -> Bool {
        try validateAppKey(appKey)
        try StoreDay.validate(day)
        return try database.transaction {
            _ = try requireRule(appKey: appKey, version: ruleVersion, category: category)
            try database.execute("""
                INSERT INTO notification_receipts(app_key, day, kind, rule_version, category) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(app_key, day, kind, rule_version, category) DO NOTHING
                """, [.text(appKey), .text(day), .text(kind == .blocked ? "exceeded" : "warning"), .integer(ruleVersion), .text(category.rawValue)])
            return try database.scalar("SELECT changes()") == 1
        }
    }

    /// Reminder-mode retention: only the current local day's measured data survives.
    /// Old lease evidence is deliberately discarded; this is not a blocking ledger.
    /// Settings and identities remain. A failed purge/checkpoint is reported for retry.
    public func prunePreviousDays() throws {
        let today = try StoreDay.label(at: clock(), calendar: calendar)
        try StoreDay.validate(today)
        try database.transaction {
            for table in ["clash_source_usage_minutes", "traffic_alert_events", "application_usage_minutes", "interface_usage_minutes", "daily_interface_usage",
                          "budget_leases", "notification_receipts", "daily_usage"] {
                // Fixed internal table names; all externally derived values are bound.
                try database.execute("DELETE FROM \(table) WHERE day <> ?", [.text(today)])
            }
        }
        // secure_delete clears freed cells; truncating WAL removes pre-purge frames.
        // Readers may delay checkpointing, so do not mark maintenance complete on busy.
        guard try database.scalar("PRAGMA wal_checkpoint(TRUNCATE)") == 0 else {
            throw StoreError.configuration("当天数据清理已提交，但旧 WAL 尚被占用；将重试清理。")
        }
    }

    func requireApplication(_ appKey: String) throws {
        guard try database.scalar("SELECT COUNT(*) FROM applications WHERE app_key = ?", [.text(appKey)]) == 1 else {
            throw StoreError.unknownApplication(appKey)
        }
    }

    func ruleForApp(_ key: String, category: TrafficCategory = .metered) throws -> QuotaRule? {
        try database.query("SELECT limit_bytes, warning_percent, version FROM quota_rules WHERE app_key = ? AND category = ?",
                           [.text(key), .text(category.rawValue)]) { try Self.readRule($0, offset: 0) }.first
    }

    func requireRule(appKey: String, version: Int64, category: TrafficCategory = .metered) throws -> QuotaRule {
        try requireApplication(appKey)
        guard let rule = try ruleForApp(appKey, category: category) else { throw StoreError.missingRule(appKey) }
        guard rule.version == version else { throw StoreError.staleRuleVersion }
        return rule
    }

    private static func readRule(_ row: SQLiteStatement, offset: Int32) throws -> QuotaRule {
        try QuotaRule(limitBytes: row.optionalInteger(offset), warningPercent: Int(row.integer(offset + 1)),
                      version: row.integer(offset + 2))
    }

    func addUsage(appKey: String, day: String, upload: Int64, download: Int64, category: TrafficCategory = .metered) throws {
        let current = try usage(appKey: appKey, day: day, category: category)
        let newUpload = try checkedAdd(current.uploadedBytes, upload)
        let newDownload = try checkedAdd(current.downloadedBytes, download)
        _ = try checkedAdd(newUpload, newDownload)
        try database.execute("""
            INSERT INTO daily_usage(app_key, day, uploaded_bytes, downloaded_bytes, category) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(app_key, day, category) DO UPDATE SET uploaded_bytes = excluded.uploaded_bytes,
              downloaded_bytes = excluded.downloaded_bytes
            """, [.text(appKey), .text(day), .integer(newUpload), .integer(newDownload), .text(category.rawValue)])
    }

    func usage(appKey: String, day: String, category: TrafficCategory = .metered) throws -> DailyUsage {
        try database.query("SELECT uploaded_bytes, downloaded_bytes FROM daily_usage WHERE app_key = ? AND day = ? AND category = ?",
                           [.text(appKey), .text(day), .text(category.rawValue)]) {
            DailyUsage(appKey: appKey, day: day, uploadedBytes: $0.integer(0), downloadedBytes: $0.integer(1))
        }.first ?? DailyUsage(appKey: appKey, day: day, uploadedBytes: 0, downloadedBytes: 0)
    }
}
