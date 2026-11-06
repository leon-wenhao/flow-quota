import Foundation
import FlowQuotaCore
import Testing
@testable import FlowQuotaStore

struct TrafficCategoryMigrationTests {
    private func seedV4(_ fixture: StoreFixture) throws -> SQLiteConnection {
        let db = try FrozenAlertVersionThree.seed(fixture.path)
        for sql in FrozenCategoryVersionFour.schema { try db.execute(sql) }
        try db.execute("UPDATE traffic_alert_settings SET daily_interface_bytes = 999, interface_burst_bytes = NULL, window_seconds = 300, version = 17")
        try db.execute("""
            INSERT INTO traffic_alert_events VALUES
            ('AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE', ?, 'dailyInterface', '', 'interface',
             1000, 999, 0, 0, 17, ?, NULL)
            """, [.text(fixture.day), .integer(Int64(fixture.clock.now().timeIntervalSince1970 * 1000))])
        try db.execute("PRAGMA user_version = 4")
        return db
    }

    @Test func v4UpgradeRetainsLegacyBytesRulesReceiptsEventsAndDisabledSettings() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let old = try seedV4(fixture)
        let before = try FrozenAlertVersionThree.evidence(old)
        try old.close()
        let store = try fixture.open()
        #expect(try await store.trafficAlertPolicy().version == 17)
        #expect(try await store.trafficAlertPolicy().windowSeconds == 300)
        #expect(try await store.trafficAlertPolicy().interfaceBurstBytes == nil)
        #expect(try await store.trafficAlertPolicy(category: .ordinary) == .disabled)
        #expect(try await store.loadRules(category: .ordinary).isEmpty)
        #expect(try await store.interfaceUsage(day: fixture.day, category: .ordinary) == nil)
        #expect(try await !store.hasApplicationUsage(day: fixture.day, category: .ordinary))
        let events = try await store.trafficAlertEvents(day: fixture.day)
        #expect(events.count == 1)
        #expect(events.first?.category == .metered)
        #expect(events.first?.scheduledAt == nil)
        #expect(try await store.trafficAlertEvents(day: fixture.day, category: .ordinary).isEmpty)
        let db = try SQLiteConnection(path: fixture.path)
        #expect(try FrozenAlertVersionThree.evidence(db).dropLast() == before.dropLast())
        #expect(try db.scalar("PRAGMA user_version") == 7)
        #expect(try db.query("PRAGMA integrity_check", row: { $0.text(0) }) == ["ok"])
        #expect(try db.query("PRAGMA foreign_key_check", row: { $0.text(0) }).isEmpty)
        try db.close(); try await store.close()
        let reopened = try fixture.open()
        #expect(try await reopened.trafficAlertPolicy().version == 17)
        #expect(try await reopened.trafficAlertPolicy(category: .ordinary) == .disabled)
        try await reopened.close()
    }

    @Test func midMigrationFailureRestoresOriginalTablesDataAndVersion() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let old = try seedV4(fixture)
        try old.execute("CREATE TABLE daily_usage_v5 (fault TEXT)")
        let before = try FrozenAlertVersionThree.evidence(old)
        #expect(throws: StoreError.self) { try fixture.open() }
        #expect(try old.scalar("PRAGMA user_version") == 4)
        #expect(try FrozenAlertVersionThree.evidence(old) == before)
        #expect(try old.scalar("SELECT COUNT(*) FROM traffic_alert_settings WHERE id = 1") == 1)
        #expect(try old.scalar("SELECT COUNT(*) FROM pragma_table_info('quota_rules') WHERE name = 'category'") == 0)
        try old.execute("DROP TABLE daily_usage_v5") // Remove only the injected fault.
        try old.close()
        let retried = try fixture.open()
        #expect(try await retried.trafficAlertPolicy().version == 17)
        try await retried.close()
    }

    @Test func missingLegacySettingsFailAtomicallyRatherThanInventingMeteredDefaults() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let old = try seedV4(fixture)
        try old.execute("DELETE FROM traffic_alert_settings")
        #expect(throws: StoreError.self) { try fixture.open() }
        #expect(try old.scalar("PRAGMA user_version") == 4)
        #expect(try old.scalar("SELECT COUNT(*) FROM pragma_table_info('quota_rules') WHERE name = 'category'") == 0)
        #expect(try old.scalar("SELECT COUNT(*) FROM daily_interface_usage") == 1)
        try old.close()
    }
}
