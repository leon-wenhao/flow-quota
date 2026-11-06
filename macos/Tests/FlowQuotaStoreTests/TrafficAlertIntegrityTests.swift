import Foundation
import Testing
import FlowQuotaCore
@testable import FlowQuotaStore

struct TrafficAlertIntegrityTests {
    @Test func directSQLEnforcesPolicyTypesAndRanges() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        let db = try SQLiteConnection(path: fixture.path)
        for assignment in [
            "category = 'invalid'", "category = NULL", "category = x'01'", "daily_interface_bytes = 0", "daily_interface_bytes = -1",
            "interface_burst_bytes = 1.5", "application_burst_bytes = x'01'",
            "daily_interface_bytes = 9223372036854775808", "window_seconds = NULL", "window_seconds = 59",
            "window_seconds = 901", "window_seconds = 60.5", "cooldown_seconds = 59",
            "cooldown_seconds = 86401", "cooldown_seconds = 'bad'", "version = 0", "version = NULL", "version = 1.5"
        ] {
            #expect(throws: StoreError.self) { try db.execute("UPDATE traffic_alert_settings SET \(assignment)") }
        }
        #expect(try await store.trafficAlertPolicy() == .initial)
        #expect(throws: StoreError.self) { try db.execute("INSERT INTO traffic_alert_settings SELECT * FROM traffic_alert_settings") }
        try await store.saveTrafficAlertPolicy(alertPolicy(version: Int64.max, daily: Int64.max, burst: nil, app: nil,
                                                           window: 900, cooldown: 86400))
        #expect(try db.scalar("SELECT version FROM traffic_alert_settings WHERE category = 'metered'") == Int64.max)
        try db.close(); try await store.close()
    }

    @Test func directSQLRejectsInvalidEventTypesEnumsDaysSourcesAndRanges() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        let event = fixture.alert(id: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")
        #expect(try await store.recordTrafficAlert(event))
        let db = try SQLiteConnection(path: fixture.path)
        let failures = [
            "id = NULL", "id = 'bad'", "id = 'GGGGGGGG-GGGG-4GGG-8GGG-GGGGGGGGGGGG'",
            "id = '0000000-00000-4000-8000-000000000000'", "id = lower(id)",
            "day = NULL", "day = '2026-02-29'", "day = '1900-02-29'", "day = '2026-04-31'",
            "day = '0000-01-01'", "day = '2026-11-4'", "day = '2026-11-04' || char(0) || 'x'",
            "kind = NULL", "kind = 'unknown'", "kind = 1", "source_key = NULL", "source_key = x'01'",
            "source_key = 'app:x'", "source_name = NULL", "source_name = x'01'", "source_name = ''",
            "source_name = char(9, 10, 13, 32)", "source_name = 'a' || char(0)",
            "source_name = replace(hex(zeroblob(129)), '0', 'x')", "kind = 'applicationBurst', source_key = ''",
            "kind = 'applicationBurst', source_key = char(9, 10, 32)",
            "kind = 'applicationBurst', source_key = replace(hex(zeroblob(1025)), '0', 'x')",
            "kind = 'applicationBurst', source_key = 'a' || char(0)",
            "observed_bytes = NULL", "observed_bytes = -1", "observed_bytes = threshold_bytes - 1",
            "observed_bytes = 1.5", "observed_bytes = 9223372036854775808", "observed_bytes = x'01'",
            "threshold_bytes = NULL", "threshold_bytes = 0", "threshold_bytes = 1.5", "threshold_bytes = 'bad'",
            "window_seconds = 0", "window_seconds = 901", "window_seconds = 300.5", "window_seconds = NULL",
            "observed_seconds = NULL", "observed_seconds = 0", "observed_seconds = 301", "observed_seconds = 1.5",
            "kind = 'dailyInterface'", "kind = 'dailyInterface', window_seconds = 0, observed_seconds = 1",
            "policy_version = NULL", "policy_version = 0", "policy_version = 1.5", "policy_version = 'bad'",
            "occurred_at_ms = NULL", "occurred_at_ms = 0", "occurred_at_ms = 1.5", "occurred_at_ms = x'01'",
            "occurred_at_ms = 253402300800000", "scheduled_at_ms = occurred_at_ms - 1",
            "scheduled_at_ms = 253402300800000", "scheduled_at_ms = 1.5", "scheduled_at_ms = x'01'"
        ]
        for assignment in failures {
            #expect(throws: StoreError.self, "Must reject \(assignment)") {
                try db.execute("UPDATE traffic_alert_events SET \(assignment)")
            }
        }
        #expect(throws: StoreError.self) { try db.execute("INSERT INTO traffic_alert_events SELECT * FROM traffic_alert_events") }
        #expect(try await store.trafficAlertEvents(day: fixture.day) == [event])
        try db.execute("""
            UPDATE traffic_alert_events SET day = '2000-02-29', kind = 'dailyInterface', window_seconds = 0,
              observed_seconds = 0, observed_bytes = 9223372036854775807, threshold_bytes = 9223372036854775807,
              policy_version = 9223372036854775807, occurred_at_ms = 1, scheduled_at_ms = 253402300799999
            """)
        #expect(try db.query("PRAGMA integrity_check", row: { $0.text(0) }) == ["ok"])
        #expect(try db.query("PRAGMA foreign_key_check", row: { $0.text(0) }).isEmpty)
        try db.close(); try await store.close()
    }

    @Test func UTF8LimitsAreBytesAndAcceptExactBoundaries() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        let key = String(repeating: "é", count: 1024), name = String(repeating: "é", count: 128)
        #expect(try await store.recordTrafficAlert(fixture.alert(kind: .applicationBurst, source: key, name: name)))
        for event in [fixture.alert(kind: .applicationBurst, source: key + "x", name: name),
                      fixture.alert(kind: .applicationBurst, source: "app:a", name: name + "x")] {
            await expectAlertError(.invalidEvent) { try await store.recordTrafficAlert(event) }
        }
        let db = try SQLiteConnection(path: fixture.path)
        #expect(try db.scalar("SELECT length(CAST(source_key AS BLOB)) FROM traffic_alert_events") == 2048)
        #expect(try db.scalar("SELECT length(CAST(source_name AS BLOB)) FROM traffic_alert_events") == 256)
        try db.close(); try await store.close()
    }
}
