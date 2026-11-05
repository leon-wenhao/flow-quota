import Foundation
@testable import FlowQuotaStore

// Frozen v3 DDL snapshot (2026-11-05), deliberately no production schema reference.
enum FrozenAlertVersionThree {
    static let nonemptyKey = "typeof(app_key) = 'text' AND length(trim(app_key)) > 0"
    static let dayCheck = """
        typeof(day) = 'text' AND length(day) = 10
        AND day GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
        AND CAST(substr(day, 1, 4) AS INTEGER) BETWEEN 1 AND 9999
        AND CAST(substr(day, 6, 2) AS INTEGER) BETWEEN 1 AND 12
        AND CAST(substr(day, 9, 2) AS INTEGER) BETWEEN 1 AND
          CASE CAST(substr(day, 6, 2) AS INTEGER)
          WHEN 2 THEN 28 + (CAST(substr(day, 1, 4) AS INTEGER) % 4 = 0
            AND (CAST(substr(day, 1, 4) AS INTEGER) % 100 != 0
              OR CAST(substr(day, 1, 4) AS INTEGER) % 400 = 0))
          WHEN 4 THEN 30 WHEN 6 THEN 30 WHEN 9 THEN 30 WHEN 11 THEN 30 ELSE 31 END
        """
    static let versionOne = [
        """
        CREATE TABLE applications (
          app_key TEXT NOT NULL PRIMARY KEY CHECK(\(nonemptyKey)),
          name TEXT NOT NULL CHECK(typeof(name) = 'text' AND length(trim(name)) > 0)
        )
        """,
        """
        CREATE TABLE quota_rules (
          app_key TEXT NOT NULL PRIMARY KEY REFERENCES applications(app_key),
          limit_bytes INTEGER CHECK(limit_bytes IS NULL OR (typeof(limit_bytes) = 'integer' AND limit_bytes > 0)),
          warning_percent INTEGER NOT NULL CHECK(typeof(warning_percent) = 'integer' AND warning_percent BETWEEN 1 AND 99),
          version INTEGER NOT NULL CHECK(typeof(version) = 'integer' AND version > 0)
        )
        """,
        """
        CREATE TABLE daily_usage (
          app_key TEXT NOT NULL REFERENCES applications(app_key),
          day TEXT NOT NULL CHECK(\(dayCheck)),
          uploaded_bytes INTEGER NOT NULL CHECK(typeof(uploaded_bytes) = 'integer' AND uploaded_bytes >= 0),
          downloaded_bytes INTEGER NOT NULL CHECK(typeof(downloaded_bytes) = 'integer' AND downloaded_bytes >= 0),
          PRIMARY KEY(app_key, day),
          CHECK(downloaded_bytes <= 9223372036854775807 - uploaded_bytes)
        )
        """,
        """
        CREATE TABLE notification_receipts (
          app_key TEXT NOT NULL REFERENCES applications(app_key),
          day TEXT NOT NULL CHECK(\(dayCheck)),
          kind TEXT NOT NULL CHECK(kind IN ('warning', 'exceeded')),
          rule_version INTEGER NOT NULL CHECK(typeof(rule_version) = 'integer' AND rule_version > 0),
          PRIMARY KEY(app_key, day, kind, rule_version)
        )
        """
    ]

    static let versionTwo = [
        """
        CREATE TABLE budget_leases (
          lease_id TEXT NOT NULL PRIMARY KEY CHECK(typeof(lease_id) = 'text' AND length(trim(lease_id)) > 0),
          app_key TEXT NOT NULL REFERENCES applications(app_key),
          day TEXT NOT NULL CHECK(\(dayCheck)),
          rule_version INTEGER NOT NULL CHECK(typeof(rule_version) = 'integer' AND rule_version > 0),
          reserved_bytes INTEGER NOT NULL CHECK(typeof(reserved_bytes) = 'integer' AND reserved_bytes > 0),
          expires_at_ms INTEGER NOT NULL CHECK(typeof(expires_at_ms) = 'integer' AND expires_at_ms > 0),
          uploaded_bytes INTEGER,
          downloaded_bytes INTEGER,
          CHECK((uploaded_bytes IS NULL AND downloaded_bytes IS NULL) OR
            (uploaded_bytes IS NOT NULL AND downloaded_bytes IS NOT NULL
             AND typeof(uploaded_bytes) = 'integer' AND uploaded_bytes >= 0
             AND typeof(downloaded_bytes) = 'integer' AND downloaded_bytes >= 0
             AND uploaded_bytes <= reserved_bytes AND downloaded_bytes <= reserved_bytes - uploaded_bytes))
        )
        """,
        """
        CREATE INDEX outstanding_leases ON budget_leases(app_key, day)
          WHERE uploaded_bytes IS NULL
        """
    ]

    static let versionThree = [
        """
        CREATE TABLE daily_interface_usage (
          day TEXT NOT NULL PRIMARY KEY CHECK(\(dayCheck)),
          uploaded_bytes INTEGER NOT NULL CHECK(typeof(uploaded_bytes) = 'integer' AND uploaded_bytes >= 0),
          downloaded_bytes INTEGER NOT NULL CHECK(typeof(downloaded_bytes) = 'integer' AND downloaded_bytes >= 0),
          CHECK(downloaded_bytes <= 9223372036854775807 - uploaded_bytes)
        )
        """
    ]

    static func seed(_ path: String) throws -> SQLiteConnection {
        let db = try SQLiteConnection(path: path)
        for sql in versionOne + versionTwo + versionThree { try db.execute(sql) }
        for sql in [
            "INSERT INTO applications VALUES ('signed:legacy', 'Legacy app')",
            "INSERT INTO quota_rules VALUES ('signed:legacy', 9223372036854775807, 80, 7)",
            "INSERT INTO daily_usage VALUES ('signed:legacy', '2026-11-04', 123, 456)",
            "INSERT INTO daily_usage VALUES ('signed:legacy', '2026-11-03', 100, 200)",
            "INSERT INTO notification_receipts VALUES ('signed:legacy', '2026-11-04', 'warning', 7)",
            "INSERT INTO budget_leases VALUES ('pending', 'signed:legacy', '2026-11-04', 7, 20, 1793793660000, NULL, NULL)",
            "INSERT INTO budget_leases VALUES ('settled', 'signed:legacy', '2026-11-04', 7, 20, 1793793660000, 5, 8)",
            "INSERT INTO daily_interface_usage VALUES ('2026-11-04', 987, 654)",
            "PRAGMA user_version = 3"
        ] { try db.execute(sql) }
        return db
    }

    static func evidence(_ db: SQLiteConnection) throws -> [[String]] {
        let selects = [
            "SELECT quote(app_key)||quote(name) FROM applications ORDER BY app_key",
            "SELECT quote(app_key)||quote(limit_bytes)||quote(warning_percent)||quote(version) FROM quota_rules ORDER BY app_key",
            "SELECT quote(app_key)||quote(day)||quote(uploaded_bytes)||quote(downloaded_bytes) FROM daily_usage ORDER BY app_key, day",
            "SELECT quote(app_key)||quote(day)||quote(kind)||quote(rule_version) FROM notification_receipts ORDER BY app_key, day, kind, rule_version",
            "SELECT quote(lease_id)||quote(app_key)||quote(day)||quote(rule_version)||quote(reserved_bytes)||quote(expires_at_ms)||quote(uploaded_bytes)||quote(downloaded_bytes) FROM budget_leases ORDER BY lease_id",
            "SELECT quote(day)||quote(uploaded_bytes)||quote(downloaded_bytes) FROM daily_interface_usage ORDER BY day",
            "SELECT name||COALESCE(sql, '') FROM sqlite_master WHERE name NOT LIKE '%traffic_alert%' ORDER BY name"
        ]
        return try selects.map { try db.query($0) { $0.text(0) } }
    }
}
