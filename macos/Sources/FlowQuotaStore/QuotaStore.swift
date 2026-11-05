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
    public func saveRule(appKey: String, rule: QuotaRule) throws {
        try validateAppKey(appKey)
        try database.transaction {
            try requireApplication(appKey)
            if let previous = try ruleForApp(appKey) {
                if previous == rule { return }
                guard rule.version > previous.version else { throw StoreError.staleRuleVersion }
            }
            try database.execute("""
                INSERT INTO quota_rules(app_key, limit_bytes, warning_percent, version) VALUES (?, ?, ?, ?)
                ON CONFLICT(app_key) DO UPDATE SET limit_bytes = excluded.limit_bytes,
                  warning_percent = excluded.warning_percent, version = excluded.version
                """, [.text(appKey), .optional(rule.limitBytes), .integer(Int64(rule.warningPercent)),
                      .integer(rule.version)])
        }
    }

    public func loadRules() throws -> [String: QuotaRule] {
        let rows = try database.query("SELECT app_key, limit_bytes, warning_percent, version FROM quota_rules") {
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
    public func snapshot(day: String) throws -> [ApplicationSnapshot] {
        try StoreDay.validate(day)
        return try database.query("""
            SELECT a.app_key, a.name, r.limit_bytes, r.warning_percent, r.version,
                   COALESCE(u.uploaded_bytes, 0), COALESCE(u.downloaded_bytes, 0)
            FROM applications a LEFT JOIN quota_rules r ON r.app_key = a.app_key
            LEFT JOIN daily_usage u ON u.app_key = a.app_key AND u.day = ?
            ORDER BY a.app_key
            """, [.text(day)]) { row in
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
                                  ruleVersion: Int64) throws -> Bool {
        try validateAppKey(appKey)
        try StoreDay.validate(day)
        return try database.transaction {
            _ = try requireRule(appKey: appKey, version: ruleVersion)
            try database.execute("""
                INSERT INTO notification_receipts(app_key, day, kind, rule_version) VALUES (?, ?, ?, ?)
                ON CONFLICT(app_key, day, kind, rule_version) DO NOTHING
                """, [.text(appKey), .text(day), .text(kind == .blocked ? "exceeded" : "warning"), .integer(ruleVersion)])
            return try database.scalar("SELECT changes()") == 1
        }
    }

    /// Removes prior-day alert events, interface totals, receipts and settled leases;
    /// retains unresolved leases and their application usage.
    /// Call on startup/day rollover; today, rules and identities are retained.
    public func prunePreviousDays() throws {
        let today = try StoreDay.label(at: clock(), calendar: calendar)
        try StoreDay.validate(today)
        try database.transaction {
            try database.execute("DELETE FROM traffic_alert_events WHERE day < ?", [.text(today)])
            try database.execute("DELETE FROM daily_interface_usage WHERE day < ?", [.text(today)])
            try database.execute("DELETE FROM budget_leases WHERE day < ? AND uploaded_bytes IS NOT NULL", [.text(today)])
            try database.execute("DELETE FROM notification_receipts WHERE day < ?", [.text(today)])
            // Keep the complete charged balance for days with uncertain consumers.
            // Expiry/day rollover alone is never proof that a grant was not spent.
            try database.execute("""
                DELETE FROM daily_usage WHERE day < ? AND NOT EXISTS (
                  SELECT 1 FROM budget_leases b WHERE b.app_key = daily_usage.app_key
                    AND b.day = daily_usage.day AND b.uploaded_bytes IS NULL)
                """, [.text(today)])
        }
    }

    func requireApplication(_ appKey: String) throws {
        guard try database.scalar("SELECT COUNT(*) FROM applications WHERE app_key = ?", [.text(appKey)]) == 1 else {
            throw StoreError.unknownApplication(appKey)
        }
    }

    func ruleForApp(_ key: String) throws -> QuotaRule? {
        try database.query("SELECT limit_bytes, warning_percent, version FROM quota_rules WHERE app_key = ?",
                           [.text(key)]) { try Self.readRule($0, offset: 0) }.first
    }

    func requireRule(appKey: String, version: Int64) throws -> QuotaRule {
        try requireApplication(appKey)
        guard let rule = try ruleForApp(appKey) else { throw StoreError.missingRule(appKey) }
        guard rule.version == version else { throw StoreError.staleRuleVersion }
        return rule
    }

    private static func readRule(_ row: SQLiteStatement, offset: Int32) throws -> QuotaRule {
        try QuotaRule(limitBytes: row.optionalInteger(offset), warningPercent: Int(row.integer(offset + 1)),
                      version: row.integer(offset + 2))
    }

    func addUsage(appKey: String, day: String, upload: Int64, download: Int64) throws {
        let current = try usage(appKey: appKey, day: day)
        let newUpload = try checkedAdd(current.uploadedBytes, upload)
        let newDownload = try checkedAdd(current.downloadedBytes, download)
        _ = try checkedAdd(newUpload, newDownload)
        try database.execute("""
            INSERT INTO daily_usage(app_key, day, uploaded_bytes, downloaded_bytes) VALUES (?, ?, ?, ?)
            ON CONFLICT(app_key, day) DO UPDATE SET uploaded_bytes = excluded.uploaded_bytes,
              downloaded_bytes = excluded.downloaded_bytes
            """, [.text(appKey), .text(day), .integer(newUpload), .integer(newDownload)])
    }

    func usage(appKey: String, day: String) throws -> DailyUsage {
        try database.query("SELECT uploaded_bytes, downloaded_bytes FROM daily_usage WHERE app_key = ? AND day = ?",
                           [.text(appKey), .text(day)]) {
            DailyUsage(appKey: appKey, day: day, uploadedBytes: $0.integer(0), downloadedBytes: $0.integer(1))
        }.first ?? DailyUsage(appKey: appKey, day: day, uploadedBytes: 0, downloadedBytes: 0)
    }
}
