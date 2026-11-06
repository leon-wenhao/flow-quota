import Foundation
import Testing
@testable import FlowQuotaStore

struct MigrationTests {
    // Independent seeded old schema: migration tests don't generate fixtures using
    // the current production DDL and therefore can detect accidental v1 drift.
    private func versionOneFixture(_ path: String) throws -> SQLiteConnection {
        let db = try SQLiteConnection(path: path)
        for sql in LegacyVersionOne.schema { try db.execute(sql) }
        for sql in [
            "INSERT INTO applications VALUES ('legacy', 'Legacy application')",
            "INSERT INTO quota_rules VALUES ('legacy', 100, 80, 3)",
            "INSERT INTO daily_usage VALUES ('legacy', '2026-11-04', 5, 8)",
            "INSERT INTO notification_receipts VALUES ('legacy', '2026-11-04', 'warning', 3)",
            "PRAGMA user_version = 1"
        ] { try db.execute(sql) }
        return db
    }

    @Test func seededVersionOneUpgradesWithoutLosingData() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let old = try versionOneFixture(fixture.path)
        try old.close()
        let store = try fixture.open()
        let snapshot = try #require(try await store.snapshot(day: "2026-11-04").first)
        #expect(snapshot.identity.name == "Legacy application")
        #expect(snapshot.identity.key == "legacy")
        #expect(snapshot.usage.uploadedBytes == 5)
        #expect(snapshot.usage.downloadedBytes == 8)
        #expect(snapshot.usage.totalBytes == 13)
        #expect(snapshot.rule?.limitBytes == 100)
        #expect(snapshot.rule?.warningPercent == 80)
        #expect(try await store.interfaceUsage(day: "2026-11-04") == nil)
        #expect(snapshot.rule?.version == 3)
        #expect(try await !store.claimNotification(appKey: "legacy", day: "2026-11-04", kind: .warning, ruleVersion: 3))
        _ = try await store.reserveBudget(id: "migrated", appKey: "legacy", day: fixture.day,
                                          bytes: 10, ruleVersion: 3, expiresAt: fixture.expiry)
        try await store.close()
        let check = try SQLiteConnection(path: fixture.path)
        #expect(try check.scalar("PRAGMA user_version") == 8)
        #expect(try check.scalar("SELECT COUNT(*) FROM budget_leases") == 1)
        #expect(try check.scalar("SELECT COUNT(*) FROM daily_interface_usage") == 0)
        try check.close()
    }

    @Test func failedMigrationRollsBackDDLAndVersionThenCanRetry() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let old = try versionOneFixture(fixture.path)
        // v2 creates the table, then fails when creating its conflicting index.
        try old.execute("CREATE INDEX outstanding_leases ON applications(name)")
        do {
            _ = try fixture.open()
            Issue.record("Conflicting migration must fail")
        } catch let error as StoreError {
            guard case .sqlite = error else { throw error }
        }
        #expect(try old.scalar("PRAGMA user_version") == 1)
        #expect(try old.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name = 'budget_leases'") == 0)
        #expect(try old.scalar("SELECT uploaded_bytes + downloaded_bytes FROM daily_usage") == 13)
        try old.execute("DROP INDEX outstanding_leases") // Repair only the injected test fault.
        try old.close()
        let upgraded = try fixture.open()
        #expect(try await upgraded.loadRules()["legacy"]?.version == 3)
        try await upgraded.close()
    }

    @Test func futureSchemaAndBrokenForeignKeysFailWithoutRebuild() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let old = try versionOneFixture(fixture.path)
        try old.execute("PRAGMA user_version = 100")
        #expect(throws: StoreError.unsupportedSchema(100)) { try fixture.open() }
        #expect(try old.scalar("SELECT COUNT(*) FROM applications") == 1)
        #expect(try old.scalar("PRAGMA user_version") == 100)
        #expect(try old.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name = 'daily_interface_usage'") == 0)
        try old.execute("PRAGMA user_version = 1")
        try old.execute("PRAGMA foreign_keys = OFF")
        try old.execute("INSERT INTO daily_usage VALUES ('orphan', '2026-11-04', 1, 2)")
        do {
            _ = try fixture.open()
            Issue.record("Foreign-key corruption must not be silently accepted")
        } catch let error as StoreError {
            switch error {
            case .configuration, .sqlite(code: 787, message: _): break
            default: throw error
            }
        }
        #expect(try old.scalar("PRAGMA user_version") == 1)
        #expect(try old.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name = 'budget_leases'") == 0)
        try old.close()
    }

    // Frozen v2 addition, independent of StoreSchema.versionTwo.
    private func versionTwoFixture(_ path: String) throws -> SQLiteConnection {
        let db = try versionOneFixture(path)
        try db.execute("""
            CREATE TABLE budget_leases (
              lease_id TEXT NOT NULL PRIMARY KEY CHECK(typeof(lease_id) = 'text' AND length(trim(lease_id)) > 0),
              app_key TEXT NOT NULL REFERENCES applications(app_key),
              day TEXT NOT NULL CHECK(\(LegacyVersionOne.dayCheck)),
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
            """)
        try db.execute("""
            CREATE INDEX outstanding_leases ON budget_leases(app_key, day) WHERE uploaded_bytes IS NULL
            """)
        try db.execute("""
            INSERT INTO budget_leases VALUES ('old-lease', 'legacy', '2026-11-04', 3, 10, 1793793660000, NULL, NULL)
            """)
        try db.execute("PRAGMA user_version = 2")
        return db
    }

    @Test func seededVersionTwoPreservesAllAppEvidenceWithoutInterfaceBackfill() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let old = try versionTwoFixture(fixture.path)
        try old.close()
        let store = try fixture.open()
        let snapshot = try #require(try await store.snapshot(day: "2026-11-04").first)
        #expect(snapshot.identity.key == "legacy")
        #expect(snapshot.identity.name == "Legacy application")
        #expect(snapshot.usage.uploadedBytes == 5)
        #expect(snapshot.usage.downloadedBytes == 8)
        #expect(snapshot.rule?.limitBytes == 100)
        #expect(snapshot.rule?.warningPercent == 80)
        #expect(snapshot.rule?.version == 3)
        #expect(try await !store.claimNotification(appKey: "legacy", day: "2026-11-04", kind: .warning, ruleVersion: 3))
        #expect(try await store.budgetBalance(appKey: "legacy", day: "2026-11-04").chargedBytes == 23)
        #expect(try await store.interfaceUsage(day: "2026-11-04") == nil)
        try await store.close()
        let check = try SQLiteConnection(path: fixture.path)
        #expect(try check.scalar("PRAGMA user_version") == 8)
        #expect(try check.scalar("SELECT COUNT(*) FROM daily_interface_usage") == 0)
        #expect(try check.scalar("SELECT COUNT(*) FROM budget_leases WHERE lease_id = 'old-lease'") == 1)
        try check.close()
    }

    @Test func failedVersionThreePreservesVersionTwoAndCanRetry() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let old = try versionTwoFixture(fixture.path)
        // A conflicting injected table must not be treated as a completed migration.
        try old.execute("CREATE TABLE daily_interface_usage (marker TEXT)")
        try old.execute("INSERT INTO daily_interface_usage VALUES ('fixture fault')")
        #expect(throws: StoreError.self) { try fixture.open() }
        #expect(try old.scalar("PRAGMA user_version") == 2)
        #expect(try old.scalar("SELECT COUNT(*) FROM daily_interface_usage WHERE marker = 'fixture fault'") == 1)
        #expect(try old.scalar("SELECT uploaded_bytes + downloaded_bytes FROM daily_usage") == 13)
        #expect(try old.scalar("SELECT COUNT(*) FROM quota_rules WHERE version = 3") == 1)
        #expect(try old.scalar("SELECT COUNT(*) FROM budget_leases") == 1)
        try old.execute("DROP TABLE daily_interface_usage") // Repair only the injected test fault.
        try old.close()
        let store = try fixture.open()
        #expect(try await store.interfaceUsage(day: "2026-11-04") == nil)
        #expect(try await store.loadRules()["legacy"]?.version == 3)
        try await store.close()
        let check = try SQLiteConnection(path: fixture.path)
        #expect(try check.scalar("PRAGMA user_version") == 8)
        try check.close()
    }

}

// Frozen initial schema fixture, intentionally independent of StoreSchema.
private enum LegacyVersionOne {
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

    static let schema = [
        """
        CREATE TABLE applications (
          app_key TEXT NOT NULL PRIMARY KEY CHECK(typeof(app_key) = 'text' AND length(trim(app_key)) > 0),
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

}
