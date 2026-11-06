import Foundation
import Testing
import FlowQuotaCore
@testable import FlowQuotaStore

struct TrafficAlertMigrationTests {
    @Test func frozenV3UpgradePreservesEveryLegacyFieldAndSchema() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let old = try FrozenAlertVersionThree.seed(fixture.path)
        let before = try FrozenAlertVersionThree.evidence(old)
        try old.close()
        let store = try fixture.open()
        #expect(try await store.trafficAlertPolicy() == .initial)
        #expect(try await store.trafficAlertEvents(day: fixture.day).isEmpty)
        let db = try SQLiteConnection(path: fixture.path)
        #expect(try db.scalar("PRAGMA user_version") == 7)
        #expect(try FrozenAlertVersionThree.evidence(db).dropLast() == before.dropLast())
        #expect(try db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name LIKE 'traffic_alert_%'") == 2)
        #expect(try db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'traffic_alert_lookup'") == 1)
        #expect(try db.query("PRAGMA integrity_check", row: { $0.text(0) }) == ["ok"])
        #expect(try db.query("PRAGMA foreign_key_check", row: { $0.text(0) }).isEmpty)
        try db.close(); try await store.close()
        let reopened = try fixture.open()
        #expect(try await reopened.trafficAlertPolicy() == .initial)
        try await reopened.close()
    }

    @Test func existingV4WindowSurvivesNewDefaultAndReopen() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        #expect(try await store.trafficAlertPolicy().windowSeconds == 180)
        let saved = try TrafficAlertPolicy(dailyInterfaceBytes: 1_000_000_000,
            interfaceBurstBytes: 200_000_000, applicationBurstBytes: 200_000_000,
            windowSeconds: 300, cooldownSeconds: 600, version: 2)
        try await store.saveTrafficAlertPolicy(saved)
        try await store.close()
        let reopened = try fixture.open()
        #expect(try await reopened.trafficAlertPolicy() == saved)
        try await reopened.close()
    }

    @Test func indexFailureRollsBackBothTablesDefaultsAndVersionThenRetries() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let db = try FrozenAlertVersionThree.seed(fixture.path)
        let before = try FrozenAlertVersionThree.evidence(db)
        try db.execute("CREATE INDEX traffic_alert_lookup ON applications(name)")
        #expect(throws: StoreError.self) { try fixture.open() }
        #expect(try db.scalar("PRAGMA user_version") == 3)
        #expect(try db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name LIKE 'traffic_alert_%'") == 0)
        #expect(try FrozenAlertVersionThree.evidence(db) == before)
        try db.execute("DROP INDEX traffic_alert_lookup")
        let store = try fixture.open()
        #expect(try db.scalar("PRAGMA user_version") == 7)
        #expect(try FrozenAlertVersionThree.evidence(db).dropLast() == before.dropLast())
        #expect(try await store.trafficAlertPolicy() == .initial)
        try db.close(); try await store.close()
    }

    @Test func validationAfterAllV4DDLStillRollsBack() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let db = try FrozenAlertVersionThree.seed(fixture.path)
        // A legacy identity fails the existing canonical-key integrity validation
        // after v4 defaults and user_version were written, exercising late rollback.
        try db.execute("INSERT INTO applications VALUES (?, 'invalid legacy key')", [.text("signed:e\u{301}")])
        let before = try FrozenAlertVersionThree.evidence(db)
        #expect(throws: StoreError.invalidIdentifier) { try fixture.open() }
        #expect(try db.scalar("PRAGMA user_version") == 3)
        #expect(try db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'traffic_alert_%'") == 0)
        #expect(try FrozenAlertVersionThree.evidence(db) == before)
        try db.close()
    }
}
