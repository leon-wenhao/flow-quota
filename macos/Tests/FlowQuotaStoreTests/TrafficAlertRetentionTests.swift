import Foundation
import Testing
import FlowQuotaCore
@testable import FlowQuotaStore

struct TrafficAlertRetentionTests {
    @Test func capRetryAndStablePagination() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        var inserted: [TrafficAlertEvent] = []
        for number in 0..<256 {
            let id = String(format: "00000000-0000-4000-8000-%012d", number)
            let event = fixture.alert(id: id, kind: .applicationBurst, source: "signed:\(number)", observed: Int64.max)
            #expect(try await store.recordTrafficAlert(event))
            inserted.append(event)
        }
        await expectAlertError(.eventLimit) {
            try await store.recordTrafficAlert(fixture.alert(kind: .applicationBurst, source: "signed:extra"))
        }
        #expect(try await !store.recordTrafficAlert(inserted[0])) // retry at cap remains idempotent
        #expect(try await !store.recordTrafficAlert(fixture.alert(kind: .applicationBurst, source: "signed:0")))
        var pages: [TrafficAlertEvent] = []
        for offset in stride(from: 0, to: 256, by: 32) {
            pages += try await store.trafficAlertEvents(day: fixture.day, limit: 32, offset: offset)
        }
        #expect(pages.map(\.id) == inserted.reversed().map(\.id))
        #expect(try await store.trafficAlertEvents(day: fixture.day).map(\.id) == pages.map(\.id))
        #expect(try await store.trafficAlertEvents(day: fixture.day, limit: 32, offset: 256).isEmpty)
        for (limit, offset) in [(0, 0), (257, 0), (1, -1), (1, 257), (Int.max, 0), (1, Int.max)] {
            await expectAlertError(.invalidEvent) {
                try await store.trafficAlertEvents(day: fixture.day, limit: limit, offset: offset)
            }
        }
        try await store.close()
    }

    @Test func concurrentDailyAdmissionAcrossConnectionsWritesOnce() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let first = try fixture.open(), second = try fixture.open()
        let a = fixture.alert(kind: .dailyInterface), b = fixture.alert(kind: .dailyInterface)
        async let one = first.recordTrafficAlert(a)
        async let two = second.recordTrafficAlert(b)
        let results = try await [one, two]
        #expect(results.filter { $0 }.count == 1)
        #expect(try await first.trafficAlertEvents(day: fixture.day).count == 1)
        try await first.close(); try await second.close()
    }

    @Test func dayRetentionKeepsSettingsAndPruningRollsBackAsOneUnit() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        let previous = fixture.alert()
        #expect(try await store.recordTrafficAlert(previous))
        let db = try SQLiteConnection(path: fixture.path)
        try db.execute("INSERT INTO daily_interface_usage VALUES (?, 5, 8)", [.text(previous.day)])
        fixture.clock.advance(86_400)
        let current = fixture.alert()
        #expect(try await store.recordTrafficAlert(current))
        let policy = try alertPolicy()
        try await store.saveTrafficAlertPolicy(policy)
        try db.execute("""
            CREATE TRIGGER fail_prune BEFORE DELETE ON daily_interface_usage
            BEGIN SELECT RAISE(ABORT, 'test prune failure'); END
            """)
        do { try await store.prunePreviousDays(); Issue.record("Expected prune failure") }
        catch let error as StoreError { guard case .sqlite = error else { throw error } }
        #expect(try await store.trafficAlertEvents(day: previous.day).count == 1)
        #expect(try await store.interfaceUsage(day: previous.day)?.totalBytes == 13)
        try db.execute("DROP TRIGGER fail_prune")
        try await store.prunePreviousDays()
        #expect(try await store.trafficAlertEvents(day: previous.day).isEmpty)
        #expect(try await store.interfaceUsage(day: previous.day) == nil)
        #expect(try await store.trafficAlertEvents(day: current.day).count == 1)
        #expect(try await store.trafficAlertPolicy() == policy)
        try db.close(); try await store.close()
    }

    @Test func failedEventPolicyAndAckWritesRollbackAndCanRetry() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        let db = try SQLiteConnection(path: fixture.path)
        let event = fixture.alert()
        for (table, operation, trigger) in [
            ("traffic_alert_events", "INSERT", "fail_insert"),
            ("traffic_alert_settings", "UPDATE", "fail_policy"),
            ("traffic_alert_events", "UPDATE", "fail_ack")
        ] {
            try db.execute("CREATE TRIGGER \(trigger) BEFORE \(operation) ON \(table) BEGIN SELECT RAISE(ABORT, 'injected'); END")
        }
        do { _ = try await store.recordTrafficAlert(event); Issue.record("Expected insert failure") }
        catch let error as StoreError { guard case .sqlite = error else { throw error } }
        #expect(try await store.trafficAlertEvents(day: fixture.day).isEmpty)
        try db.execute("DROP TRIGGER fail_insert")
        #expect(try await store.recordTrafficAlert(event))
        do { try await store.saveTrafficAlertPolicy(alertPolicy()); Issue.record("Expected policy failure") }
        catch let error as StoreError { guard case .sqlite = error else { throw error } }
        #expect(try await store.trafficAlertPolicy() == .initial)
        do { try await store.acknowledgeTrafficAlert(id: event.id, day: event.day); Issue.record("Expected ACK failure") }
        catch let error as StoreError { guard case .sqlite = error else { throw error } }
        #expect(try await store.trafficAlertEvents(day: fixture.day).first?.scheduledAt == nil)
        try db.execute("DROP TRIGGER fail_ack")
        try await store.acknowledgeTrafficAlert(id: event.id, day: event.day)
        #expect(try await store.trafficAlertEvents(day: fixture.day).first?.scheduledAt != nil)
        try db.execute("DROP TRIGGER fail_policy")
        try await store.saveTrafficAlertPolicy(alertPolicy())
        try db.close(); try await store.close()
    }

    @Test func compositeIndexCoversAdmissionAndBoundsDayQueries() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        // Representative maximum evidence population, not an empty planner fixture.
        for number in 0..<256 {
            #expect(try await store.recordTrafficAlert(fixture.alert(kind: .applicationBurst, source: "app:\(number)")))
        }
        let db = try SQLiteConnection(path: fixture.path)
        let queries = [
            "SELECT MAX(occurred_at_ms) FROM traffic_alert_events WHERE day = ? AND kind = 'applicationBurst' AND source_key = 'app:1' AND policy_version = 1",
            "SELECT COUNT(*) FROM traffic_alert_events WHERE day = ?",
            "SELECT * FROM traffic_alert_events WHERE day = ? ORDER BY occurred_at_ms DESC, id DESC LIMIT 32 OFFSET 32",
            "DELETE FROM traffic_alert_events WHERE day < ?"
        ]
        for query in queries {
            let plan = try db.query("EXPLAIN QUERY PLAN " + query, [.text(fixture.day)]) { $0.text(3) }.joined(separator: " ")
            #expect(plan.contains("traffic_alert_lookup"))
            #expect(!plan.contains("SCAN traffic_alert_events"))
        }
        #expect(try db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'traffic_alert_lookup'") == 1)
        try db.close(); try await store.close()
    }
}
