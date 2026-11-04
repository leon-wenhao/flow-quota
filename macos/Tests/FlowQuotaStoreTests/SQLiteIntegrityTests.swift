import Foundation
import Testing
@testable import FlowQuotaStore

struct SQLiteIntegrityTests {
    @Test func connectionConfigurationAndDatabaseConstraints() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let db = try SQLiteConnection(path: fixture.path)
        let version = try db.query("SELECT sqlite_version()") { $0.text(0) }
        print("FlowQuotaStore linked SQLite: \(version)")
        #expect(throws: StoreError.configuration("Incorrect SQL binding count")) {
            try db.execute("SELECT ?")
        }
        #expect(throws: StoreError.self) { try db.execute("INVALID SQL") }
        #expect(try db.scalar("PRAGMA foreign_keys") == 1)
        #expect(try db.scalar("PRAGMA synchronous") == 2)
        #expect(try db.scalar("PRAGMA busy_timeout") == 1_000)
        #expect(try db.scalar("PRAGMA wal_autocheckpoint") == 1_000)
        #expect(try db.query("PRAGMA journal_mode", row: { $0.text(0) }) == ["wal"])
        for sql in [
            "INSERT INTO applications VALUES (NULL, 'invalid')",
            "INSERT INTO applications VALUES ('', 'invalid')",
            "INSERT INTO quota_rules VALUES ('orphan', 100, 80, 1)",
            "UPDATE quota_rules SET limit_bytes = 0",
            "UPDATE quota_rules SET limit_bytes = 1.5",
            "UPDATE quota_rules SET warning_percent = 100",
            "UPDATE quota_rules SET version = -1",
            "INSERT INTO daily_usage VALUES ('orphan', '2026-11-04', 1, 0)",
            "INSERT INTO daily_usage VALUES ('signed:app', '2026-02-29', 1, 0)",
            "INSERT INTO daily_usage VALUES ('signed:app', '1900-02-29', 1, 0)",
            "INSERT INTO daily_usage VALUES ('signed:app', '2026-04-31', 1, 0)",
            "INSERT INTO daily_usage VALUES ('signed:app', '0000-01-01', 1, 0)",
            "INSERT INTO daily_usage VALUES ('signed:app', '2026-11-04', -1, 0)",
            "INSERT INTO daily_usage VALUES ('signed:app', '2026-11-04', 1.5, 0)",
            "INSERT INTO daily_usage VALUES ('signed:app', '2026-11-04', 9223372036854775807, 1)",
            "INSERT INTO notification_receipts VALUES ('orphan', '2026-11-04', 'warning', 1)",
            "INSERT INTO notification_receipts VALUES ('signed:app', '2026-11-04', 'other', 1)",
            "INSERT INTO notification_receipts VALUES ('signed:app', '2026-11-04', 'warning', 0)",
            "INSERT INTO budget_leases VALUES ('bad', 'orphan', '2026-11-04', 1, 10, 1000, NULL, NULL)",
            "INSERT INTO budget_leases VALUES ('bad', 'signed:app', '2026-11-04', 1, 0, 1000, NULL, NULL)",
            "INSERT INTO budget_leases VALUES ('bad', 'signed:app', '2026-11-04', 1, 10, 1000, 1, NULL)",
            "INSERT INTO budget_leases VALUES ('bad', 'signed:app', '2026-11-04', 1, 10, 1000, 9, 2)",
            "DELETE FROM applications WHERE app_key = 'signed:app'"
        ] {
            #expect(throws: StoreError.self) { try db.execute(sql) }
        }
        try db.execute("INSERT INTO daily_usage VALUES ('signed:app', '2000-02-29', 1, 2)")
        #expect(throws: StoreError.self) {
            try db.execute("INSERT INTO daily_usage VALUES ('signed:app', '2000-02-29', 1, 2)")
        }
        #expect(try db.scalar("SELECT COUNT(*) FROM daily_usage") == 1)
        #expect(try db.query("PRAGMA integrity_check", row: { $0.text(0) }) == ["ok"])
        #expect(try db.query("PRAGMA foreign_key_check", row: { $0.text(0) }).isEmpty)
        try db.close()
        try await store.close()
    }

    @Test func queryPlansUseCompositeKeysAndPartialLiabilityIndex() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        let db = try SQLiteConnection(path: fixture.path)
        try db.transaction {
            for index in 0..<200 {
                let key = "app-\(index)"
                try db.execute("INSERT INTO applications VALUES (?, ?)", [.text(key), .text(key)])
                try db.execute("INSERT INTO quota_rules VALUES (?, 100000, 80, 1)", [.text(key)])
                try db.execute("INSERT INTO daily_usage VALUES (?, ?, 1, 2)", [.text(key), .text(fixture.day)])
                try db.execute("""
                    INSERT INTO budget_leases(lease_id, app_key, day, rule_version, reserved_bytes, expires_at_ms)
                    VALUES (?, ?, ?, 1, 5, 1793793660000)
                    """, [.text(key), .text(key), .text(fixture.day)])
            }
        }
        let liabilityPlan = try db.query("""
            EXPLAIN QUERY PLAN SELECT COALESCE(SUM(reserved_bytes), 0) FROM budget_leases
            WHERE app_key = ? AND day = ? AND uploaded_bytes IS NULL
            """, [.text("app-42"), .text(fixture.day)]) { $0.text(3) }
        #expect(liabilityPlan.contains { $0.contains("SEARCH") && $0.contains("outstanding_leases") })
        let usagePlan = try db.query("""
            EXPLAIN QUERY PLAN SELECT uploaded_bytes, downloaded_bytes FROM daily_usage WHERE app_key = ? AND day = ?
            """, [.text("app-42"), .text(fixture.day)]) { $0.text(3) }
        #expect(usagePlan.contains { $0.contains("SEARCH") && $0.contains("app_key=? AND day=?") })
        let snapshotPlan = try db.query("""
            EXPLAIN QUERY PLAN SELECT a.app_key, r.version, u.uploaded_bytes FROM applications a
            LEFT JOIN quota_rules r ON r.app_key = a.app_key
            LEFT JOIN daily_usage u ON u.app_key = a.app_key AND u.day = ?
            """, [.text(fixture.day)]) { $0.text(3) }
        #expect(snapshotPlan.contains { $0.contains("SEARCH r") && $0.contains("INDEX") })
        #expect(snapshotPlan.contains { $0.contains("SEARCH u") && $0.contains("app_key=? AND day=?") })
        #expect(try await store.budgetBalance(appKey: "app-42", day: fixture.day).chargedBytes == 8)
        try db.close()
        try await store.close()
    }

    @Test func cleanupRemovesOnlyResolvedPastEvidence() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let day = fixture.day
        try await store.recordUsage(appKey: "signed:app", day: day, uploadedBytes: 1, downloadedBytes: 1)
        _ = try await store.reserveBudget(id: "settled", appKey: "signed:app", day: day,
                                          bytes: 10, ruleVersion: 1, expiresAt: fixture.expiry)
        _ = try await store.settleBudget(id: "settled", uploadedBytes: 4, downloadedBytes: 1)
        _ = try await store.claimNotification(appKey: "signed:app", day: day, kind: .warning, ruleVersion: 1)
        try await store.prunePreviousDays()
        #expect(try await store.budgetBalance(appKey: "signed:app", day: day).chargedBytes == 7)
        fixture.clock.advance(86_400)
        try await store.prunePreviousDays()
        let db = try SQLiteConnection(path: fixture.path)
        for table in ["daily_usage", "notification_receipts", "budget_leases"] {
            #expect(try db.scalar("SELECT COUNT(*) FROM \(table)") == 0)
        }
        #expect(try db.scalar("SELECT COUNT(*) FROM quota_rules") == 1)
        #expect(try db.scalar("SELECT COUNT(*) FROM applications") == 1)
        try db.close()
        try await store.close()
    }
}
