import Foundation
import FlowQuotaCore
import Testing
@testable import FlowQuotaStore

struct TrafficCategoryPersistenceTests {
    @Test func countersRulesVersionsAndReceiptsAreIndependentAndSurviveRestart() async throws {
        let f = try StoreFixture()
        defer { f.cleanup() }
        let store = try f.open()
        let app = AppIdentity(key: "signed:category", name: "Category app")
        let rule = try QuotaRule(limitBytes: 100, version: 1)
        for (category, bytes) in [(TrafficCategory.metered, Int64(60)), (.ordinary, 500)] {
            try await store.recordSample(day: f.day, increments: [UsageIncrement(identity: app, uploadedBytes: bytes, downloadedBytes: 0)],
                interfaceIncrement: InterfaceUsage(day: f.day, uploadedBytes: bytes * 2, downloadedBytes: 0), category: category)
            try await store.saveRule(appKey: app.key, rule: rule, category: category)
            #expect(try await store.claimNotification(appKey: app.key, day: f.day, kind: .warning, ruleVersion: 1, category: category))
            #expect(try await !store.claimNotification(appKey: app.key, day: f.day, kind: .warning, ruleVersion: 1, category: category))
        }
        try await store.saveRule(appKey: app.key, rule: QuotaRule(limitBytes: 200, version: 2), category: .ordinary)
        #expect(try await store.loadRules()[app.key]?.version == 1)
        #expect(try await store.loadRules(category: .ordinary)[app.key]?.version == 2)
        #expect(try await store.deliveredNotifications(day: f.day).first?.category == .metered)
        #expect(try await store.deliveredNotifications(day: f.day, category: .ordinary).first?.category == .ordinary)
        try await store.close()
        let reopened = try f.open()
        #expect(try await reopened.snapshot(day: f.day).first?.usage.totalBytes == 60)
        #expect(try await reopened.snapshot(day: f.day, category: .ordinary).first?.usage.totalBytes == 500)
        #expect(try await reopened.interfaceUsage(day: f.day)?.totalBytes == 120)
        #expect(try await reopened.interfaceUsage(day: f.day, category: .ordinary)?.totalBytes == 1000)
        let db = try SQLiteConnection(path: f.path)
        let plan = try db.query("EXPLAIN QUERY PLAN SELECT uploaded_bytes FROM daily_usage WHERE app_key = ? AND day = ? AND category = ?",
            [.text(app.key), .text(f.day), .text("ordinary")]) { $0.text(3) }
        #expect(plan.contains { $0.contains("USING INDEX") })
        try db.close(); try await reopened.close()
    }

    @Test func policiesCooldownAckAndDailyDedupDoNotCrossCategories() async throws {
        let f = try StoreFixture()
        defer { f.cleanup() }
        let store = try f.open()
        let enabled = try TrafficAlertPolicy(dailyInterfaceBytes: 100, interfaceBurstBytes: 100,
            applicationBurstBytes: nil, version: 2)
        for category in TrafficCategory.allCases {
            try await store.saveTrafficAlertPolicy(enabled, category: category)
            let event = TrafficAlertEvent(category: category, day: f.day, kind: .dailyInterface,
                sourceName: "interface", observedBytes: 120, thresholdBytes: 100, windowSeconds: 0,
                observedSeconds: 0, policyVersion: 2, occurredAt: f.clock.now())
            #expect(try await store.recordTrafficAlert(event))
            let duplicate = TrafficAlertEvent(category: category, day: f.day, kind: .dailyInterface,
                sourceName: "interface", observedBytes: 200, thresholdBytes: 100, windowSeconds: 0,
                observedSeconds: 0, policyVersion: 2, occurredAt: f.clock.now())
            #expect(try await !store.recordTrafficAlert(duplicate))
            try await store.acknowledgeTrafficAlert(id: event.id, day: f.day)
            let burst = TrafficAlertEvent(category: category, day: f.day, kind: .interfaceBurst,
                sourceName: "interface", observedBytes: 120, thresholdBytes: 100, windowSeconds: 180,
                observedSeconds: 2, policyVersion: 2, occurredAt: f.clock.now())
            #expect(try await store.recordTrafficAlert(burst))
        }
        try await store.saveTrafficAlertPolicy(TrafficAlertPolicy(dailyInterfaceBytes: nil,
            interfaceBurstBytes: nil, applicationBurstBytes: nil, version: 3), category: .ordinary)
        #expect(try await store.trafficAlertPolicy() == enabled)
        #expect(try await store.trafficAlertEvents(day: f.day).count == 2)
        #expect(try await store.trafficAlertEvents(day: f.day, category: .ordinary).count == 2)
        let db = try SQLiteConnection(path: f.path)
        let plan = try db.query("EXPLAIN QUERY PLAN SELECT MAX(occurred_at_ms) FROM traffic_alert_events WHERE day = ? AND category = ? AND kind = ? AND source_key = ? AND policy_version = ?",
            [.text(f.day), .text("ordinary"), .text("interfaceBurst"), .text(""), .integer(2)]) { $0.text(3) }
        #expect(plan.contains { $0.contains("traffic_alert_lookup") })
        try db.close()
        let previousDay = f.day
        f.clock.advance(86_400)
        try await store.prunePreviousDays()
        for category in TrafficCategory.allCases {
            #expect(try await store.trafficAlertEvents(day: previousDay, category: category).isEmpty)
        }
        try await store.close()
    }

    @Test func ordinaryBatchFailureRollsBackAndCannotConsumeMeteredLeaseBudget() async throws {
        let f = try StoreFixture()
        defer { f.cleanup() }
        let store = try f.open()
        try await f.seed(store)
        _ = try await store.reserveBudget(id: "held", appKey: "signed:app", day: f.day,
            bytes: 90, ruleVersion: 1, expiresAt: f.expiry)
        let increment = UsageIncrement(identity: AppIdentity(key: "signed:app", name: "App"), uploadedBytes: 1000, downloadedBytes: 0)
        try await store.recordSample(day: f.day, increments: [increment], category: .ordinary)
        #expect(try await store.budgetBalance(appKey: "signed:app", day: f.day).chargedBytes == 90)
        do {
            try await store.recordSample(day: f.day, increments: [increment],
                interfaceIncrement: InterfaceUsage(day: f.day, uploadedBytes: -1, downloadedBytes: 0), category: .ordinary)
            Issue.record("Invalid interface sample must roll back its application batch")
        } catch {}
        #expect(try await store.snapshot(day: f.day, category: .ordinary).first?.usage.totalBytes == 1000)
        #expect(try await store.interfaceUsage(day: f.day, category: .ordinary) == nil)
        try await store.close()
    }
}
