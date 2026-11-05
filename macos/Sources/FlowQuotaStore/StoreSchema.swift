import Foundation

enum StoreSchema {
    static let currentVersion: Int64 = 4
    static let nonemptyKey = "typeof(app_key) = 'text' AND length(trim(app_key)) > 0"

    static func migrate(_ database: SQLiteConnection) throws {
        try database.transaction {
            let version = try database.scalar("PRAGMA user_version")
            guard (0...currentVersion).contains(version) else {
                throw StoreError.unsupportedSchema(version)
            }
            if version < 1 {
                for sql in versionOne { try database.execute(sql) }
                try database.execute("PRAGMA user_version = 1")
            }
            if version < 2 {
                for sql in versionTwo { try database.execute(sql) }
                try database.execute("PRAGMA user_version = 2")
            }
            if version < 3 {
                // Independent meter: old application counters cannot backfill it.
                for sql in versionThree { try database.execute(sql) }
                try database.execute("PRAGMA user_version = 3")
            }
            if version < 4 {
                for sql in versionFour { try database.execute(sql) }
                try database.execute("PRAGMA user_version = 4")
            }
            // Reject legacy collisions explicitly; never merge or discard usage.
            let keys = try database.query("SELECT app_key FROM applications") { $0.text(0) }
            for key in keys { try validateAppKey(key) }
            let violations = try database.query("PRAGMA foreign_key_check") { $0.text(0) }
            guard violations.isEmpty else {
                throw StoreError.configuration("Foreign-key violations in persisted ledger: \(violations)")
            }
        }
    }

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
          day TEXT NOT NULL CHECK(\(StoreDay.sqlCheck)),
          uploaded_bytes INTEGER NOT NULL CHECK(typeof(uploaded_bytes) = 'integer' AND uploaded_bytes >= 0),
          downloaded_bytes INTEGER NOT NULL CHECK(typeof(downloaded_bytes) = 'integer' AND downloaded_bytes >= 0),
          PRIMARY KEY(app_key, day),
          CHECK(downloaded_bytes <= 9223372036854775807 - uploaded_bytes)
        )
        """,
        """
        CREATE TABLE notification_receipts (
          app_key TEXT NOT NULL REFERENCES applications(app_key),
          day TEXT NOT NULL CHECK(\(StoreDay.sqlCheck)),
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
          day TEXT NOT NULL CHECK(\(StoreDay.sqlCheck)),
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
          day TEXT NOT NULL PRIMARY KEY CHECK(\(StoreDay.sqlCheck)),
          uploaded_bytes INTEGER NOT NULL CHECK(typeof(uploaded_bytes) = 'integer' AND uploaded_bytes >= 0),
          downloaded_bytes INTEGER NOT NULL CHECK(typeof(downloaded_bytes) = 'integer' AND downloaded_bytes >= 0),
          CHECK(downloaded_bytes <= 9223372036854775807 - uploaded_bytes)
        )
        """
    ]
}
