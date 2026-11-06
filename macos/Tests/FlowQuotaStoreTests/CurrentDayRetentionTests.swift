import Foundation
import Testing
import FlowQuotaCore
@testable import FlowQuotaStore

struct CurrentDayRetentionTests {
    @Test func onlyCurrentDaySurvivesIncludingUnsettledLeasesAndClockRollback() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        try await fixture.seed(store)
        for _ in 0..<3 {
            for category in TrafficCategory.allCases {
                try await store.saveRule(appKey: "signed:app", rule: QuotaRule(limitBytes: 100), category: category)
                try await store.recordSample(day: fixture.day, increments: [UsageIncrement(
                    identity: AppIdentity(key: "signed:app", name: "Application"), uploadedBytes: 2, downloadedBytes: 3)],
                    interfaceIncrement: InterfaceUsage(day: fixture.day, uploadedBytes: 4, downloadedBytes: 5),
                    category: category, applicationObservedAt: fixture.clock.now(),
                    observedApplicationKeys: ["signed:app"], interfaceObservedAt: fixture.clock.now())
                #expect(try await store.claimNotification(appKey: "signed:app", day: fixture.day,
                    kind: .warning, ruleVersion: 1, category: category))
            }
            _ = try await store.reserveBudget(id: fixture.day, appKey: "signed:app", day: fixture.day,
                bytes: 10, ruleVersion: 1, expiresAt: fixture.expiry)
            #expect(try await store.recordTrafficAlert(fixture.alert()))
            fixture.clock.advance(86_400)
        }
        fixture.clock.advance(-2 * 86_400) // Simulate clock rollback; only the middle day remains.
        let today = fixture.day
        let db = try SQLiteConnection(path: fixture.path)
        #expect(try db.scalar("PRAGMA secure_delete") == 1)
        try await store.prunePreviousDays()
        for table in ["daily_usage", "daily_interface_usage", "interface_usage_minutes", "application_usage_minutes",
                      "budget_leases", "notification_receipts", "traffic_alert_events"] {
            #expect(try db.query("SELECT DISTINCT day FROM \(table)", row: { $0.text(0) }) == [today])
        }
        #expect(try await store.loadRules().count == 1)
        #expect(try await store.loadRules(category: .ordinary).count == 1)
        #expect(try db.scalar("SELECT COUNT(*) FROM traffic_alert_settings") == 2)
        #expect(try db.scalar("SELECT COUNT(*) FROM applications") == 1)
        #expect(try db.query("PRAGMA integrity_check", row: { $0.text(0) }) == ["ok"])
        #expect(try db.query("PRAGMA foreign_key_check", row: { $0.text(0) }).isEmpty)
        let wal = fixture.path + "-wal"
        #expect((try FileManager.default.attributesOfItem(atPath: wal)[.size] as? NSNumber)?.intValue == 0)
        try db.close()
        try await store.close()
        let reopened = try fixture.open()
        try await reopened.prunePreviousDays()
        #expect(try await reopened.budgetBalance(appKey: "signed:app", day: today).outstandingBytes == 10)
        try await reopened.close()
    }
}
