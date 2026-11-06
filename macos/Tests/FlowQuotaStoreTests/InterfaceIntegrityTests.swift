import Foundation
import Testing
import FlowQuotaCore
@testable import FlowQuotaStore

struct InterfaceIntegrityTests {
    @Test func interfaceTableEnforcesIntegerDateAndPrimaryKeyConstraints() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        let db = try SQLiteConnection(path: fixture.path)
        for values in [
            "NULL, 0, 0", "'', 0, 0", "'2026-11-4', 0, 0", "'0000-01-01', 0, 0",
            "'2026-02-29', 0, 0", "'1900-02-29', 0, 0", "'2026-04-31', 0, 0",
            "'2026-00-01', 0, 0", "'2026-13-01', 0, 0", "'2026-01-00', 0, 0",
            "'2026-11-04', NULL, 0", "'2026-11-04', 0, NULL",
            "'2026-11-04', -1, 0", "'2026-11-04', 0, -1",
            "'2026-11-04', 1.5, 0", "'2026-11-04', 0, 1.5",
            "'2026-11-04', 'invalid', 0", "'2026-11-04', 0, x'01'",
            "'2026-11-04', 9223372036854775807, 1",
            "'2026-11-04', 1, 9223372036854775807",
            "'2026-11-04', 9223372036854775808, 0"
        ] {
            #expect(throws: StoreError.self) {
                try db.execute("INSERT INTO daily_interface_usage (day, uploaded_bytes, downloaded_bytes) VALUES (\(values))")
            }
        }
        #expect(try db.scalar("SELECT COUNT(*) FROM daily_interface_usage") == 0)
        try db.execute("INSERT INTO daily_interface_usage (day, uploaded_bytes, downloaded_bytes) VALUES ('2000-02-29', 0, 0)")
        try db.execute("INSERT INTO daily_interface_usage (day, uploaded_bytes, downloaded_bytes) VALUES ('0001-01-01', 9223372036854775807, 0)")
        try db.execute("INSERT INTO daily_interface_usage (day, uploaded_bytes, downloaded_bytes) VALUES ('9999-12-31', 0, 9223372036854775807)")
        #expect(throws: StoreError.self) {
            try db.execute("INSERT INTO daily_interface_usage (day, uploaded_bytes, downloaded_bytes) VALUES ('2000-02-29', 1, 2)")
        }
        #expect(throws: StoreError.self) {
            try db.execute("UPDATE daily_interface_usage SET uploaded_bytes = uploaded_bytes + 1 WHERE day = '0001-01-01'")
        }
        #expect(try db.scalar("SELECT COUNT(*) FROM daily_interface_usage") == 3)
        #expect(try db.query("PRAGMA integrity_check", row: { $0.text(0) }) == ["ok"])
        #expect(try db.query("PRAGMA foreign_key_check", row: { $0.text(0) }).isEmpty)
        try db.close()
        try await store.close()
    }

    @Test func interfaceFailureRollsBackAppNamesIdentitiesAndBothMeters() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let initial = InterfaceUsage(day: fixture.day, uploadedBytes: 10, downloadedBytes: 20)
        try await store.recordSample(day: fixture.day, increments: [
            UsageIncrement(identity: AppIdentity(key: "signed:app", name: "Application"),
                           uploadedBytes: 1, downloadedBytes: 2)
        ], interfaceIncrement: initial)
        let db = try SQLiteConnection(path: fixture.path)
        try db.execute("""
            CREATE TRIGGER injected_interface_failure BEFORE UPDATE ON daily_interface_usage
            BEGIN SELECT RAISE(ABORT, 'injected interface failure'); END
            """)
        do {
            try await store.recordSample(day: fixture.day, increments: [
                UsageIncrement(identity: AppIdentity(key: "signed:app", name: "Changed"),
                               uploadedBytes: 4, downloadedBytes: 5),
                UsageIncrement(identity: AppIdentity(key: "new", name: "New"),
                               uploadedBytes: 6, downloadedBytes: 7)
            ], interfaceIncrement: InterfaceUsage(day: fixture.day, uploadedBytes: 8, downloadedBytes: 9))
            Issue.record("Injected interface write failure must fail the entire sample")
        } catch let error as StoreError {
            guard case .sqlite = error else { throw error }
        }
        let snapshots = try await store.snapshot(day: fixture.day)
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.identity.name == "Application")
        #expect(snapshots.first?.usage.uploadedBytes == 1)
        #expect(snapshots.first?.usage.downloadedBytes == 2)
        #expect(try await store.interfaceUsage(day: fixture.day) == initial)
        #expect(try await store.loadRules()["signed:app"]?.version == 1)
        try db.execute("DROP TRIGGER injected_interface_failure")
        try db.close()
        try await store.close()
    }

    @Test func interfaceLookupUsesDayPrimaryKey() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        let db = try SQLiteConnection(path: fixture.path)
        try db.transaction {
            for year in 2000..<2200 {
                try db.execute("INSERT INTO daily_interface_usage (day, uploaded_bytes, downloaded_bytes) VALUES (?, 1, 2)", [.text("\(year)-01-01")])
            }
        }
        let plan = try db.query("""
            EXPLAIN QUERY PLAN SELECT uploaded_bytes, downloaded_bytes FROM daily_interface_usage WHERE day = ?
            """, [.text("2042-01-01")]) { $0.text(3) }
        #expect(plan.contains { $0.contains("SEARCH") && $0.contains("INDEX") && $0.contains("day=?") })
        #expect(try await store.interfaceUsage(day: "2042-01-01")?.totalBytes == 3)
        #expect(try db.scalar("SELECT COUNT(*) FROM applications") == 0)
        try db.close()
        try await store.close()
    }
}
