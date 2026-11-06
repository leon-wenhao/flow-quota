import Foundation
import Testing
import FlowQuotaCore
@testable import FlowQuotaStore

struct TrafficAlertApplicationTests {
    private func evidence(_ f: StoreFixture, up: Int64 = 12) -> TrafficAlertApplications {
        TrafficAlertApplications(items: [TrafficAlertApplication(identity: AppIdentity(key: "signed:browser", name: "Browser"),
            uploadedBytes: up, downloadedBytes: 34)], observedAt: f.clock.now())
    }
    private func event(_ f: StoreFixture, id: String = UUID().uuidString,
                       applications: TrafficAlertApplications?) -> TrafficAlertEvent {
        TrafficAlertEvent(id: id, day: f.day, kind: .interfaceBurst, sourceName: "Physical interface",
            observedBytes: 200_000_000, thresholdBytes: 200_000_000, windowSeconds: 180,
            observedSeconds: 10, policyVersion: 1, occurredAt: f.clock.now(), applications: applications)
    }

    @Test func snapshotIsImmutableAcrossLedgerChangesAckReopenAndExactRetries() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        let store = try f.open()
        let alert = event(f, applications: evidence(f))
        #expect(try await store.recordTrafficAlert(alert))
        try await store.recordSample(day: f.day, increments: [UsageIncrement(
            identity: AppIdentity(key: "signed:browser", name: "Renamed browser"), uploadedBytes: 999, downloadedBytes: 888)])
        #expect(try await !store.recordTrafficAlert(alert))
        await expectStoreError(.trafficAlertConflict) {
            try await store.recordTrafficAlert(event(f, id: alert.id, applications: evidence(f, up: 13)))
        }
        try await store.acknowledgeTrafficAlert(id: alert.id, day: f.day)
        try await store.close()
        let reopened = try f.open()
        let saved = try await reopened.trafficAlertDetails(id: alert.id, day: f.day, category: .metered)
        #expect(saved.applications == alert.applications)
        #expect(saved.scheduledAt != nil)
        #expect(try await !reopened.recordTrafficAlert(alert))
        await expectStoreError(.unknownTrafficAlert(alert.id)) {
            try await reopened.trafficAlertDetails(id: alert.id, day: f.day, category: .ordinary)
        }
        f.clock.advance(86_400)
        try await reopened.prunePreviousDays()
        #expect(try await reopened.trafficAlertEvents(day: f.day).isEmpty)
        await expectStoreError(.inactiveDay) {
            try await reopened.trafficAlertDetails(id: alert.id, day: alert.day, category: .metered)
        }
        let db = try SQLiteConnection(path: f.path)
        #expect(try db.scalar("SELECT COUNT(*) FROM traffic_alert_events") == 0)
        try db.close(); try await reopened.close()
    }

    @Test func v7UpgradeKeepsOldEventsNullAndMigrationFailureRollsBack() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        let store = try f.open()
        let oldEvent = event(f, applications: nil)
        #expect(try await store.recordTrafficAlert(oldEvent))
        try await store.close()
        let db = try SQLiteConnection(path: f.path)
        try db.execute("PRAGMA user_version = 7")
        // A column conflict models failed DDL; never silently mark v8 complete.
        #expect(throws: StoreError.self) { try f.open() }
        #expect(try db.scalar("PRAGMA user_version") == 7)
        #expect(try db.scalar("SELECT COUNT(*) FROM traffic_alert_events") == 1)
        try db.execute("ALTER TABLE traffic_alert_events DROP COLUMN applications_json")
        let upgraded = try f.open()
        #expect(try db.scalar("PRAGMA user_version") == 8)
        let saved = try await upgraded.trafficAlertEvents(day: f.day)
        #expect(saved == [oldEvent])
        #expect(saved.first?.applications == nil && saved.first?.applicationSummary == nil)
        #expect(try db.query("PRAGMA integrity_check", row: { $0.text(0) }) == ["ok"])
        try db.close(); try await upgraded.close()
    }

    @Test func dailySnapshotsSeparateCategoriesCapRowsAndRejectCorruptJSON() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        let store = try f.open()
        let missing = try await store.dailyAlertApplications(day: f.day, category: .ordinary, observedAt: f.clock.now())
        #expect(missing.observedAt == nil)
        let increments = (0..<130).map {
            UsageIncrement(identity: AppIdentity(key: "signed:app\($0)", name: "App \($0)"),
                uploadedBytes: Int64($0), downloadedBytes: 1)
        }
        try await store.recordSample(day: f.day, increments: increments)
        let apps = try await store.dailyAlertApplications(day: f.day, category: .metered, observedAt: f.clock.now())
        #expect(apps.items.count == 128 && apps.omittedCount == 2)
        #expect(apps.items.first?.identity.key == "signed:app129")
        #expect(try await store.dailyAlertApplications(day: f.day, category: .ordinary, observedAt: f.clock.now()).items.isEmpty)
        let alert = event(f, applications: apps)
        #expect(try await store.recordTrafficAlert(alert))
        let db = try SQLiteConnection(path: f.path)
        #expect(throws: StoreError.self) {
            try db.execute("UPDATE traffic_alert_events SET applications_json = ? WHERE id = ?",
                [.text(String(repeating: "x", count: 524289)), .text(alert.id)])
        }
        try db.execute("UPDATE traffic_alert_events SET applications_json = '{}' WHERE id = ?", [.text(alert.id)])
        do { _ = try await store.trafficAlertEvents(day: f.day); Issue.record("Corrupt evidence must be visible") } catch {}
        try db.close(); try await store.close()
    }
}
