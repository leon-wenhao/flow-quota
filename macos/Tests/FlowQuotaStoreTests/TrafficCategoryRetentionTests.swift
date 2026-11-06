import Foundation
import FlowQuotaCore
import Testing
@testable import FlowQuotaStore

@Test func eventCapacityIsSharedAndDayCleanupRemovesBothCategoryLedgers() async throws {
    let f = try StoreFixture()
    defer { f.cleanup() }
    let store = try f.open()
    let day = f.day
    let policy = try TrafficAlertPolicy(dailyInterfaceBytes: nil, interfaceBurstBytes: nil,
        applicationBurstBytes: 10, version: 2)
    for category in TrafficCategory.allCases {
        try await store.saveTrafficAlertPolicy(policy, category: category)
        for index in 0..<128 {
            let event = TrafficAlertEvent(category: category, day: day, kind: .applicationBurst,
                sourceKey: "exec:/source-\(index)", sourceName: "Source", observedBytes: 12,
                thresholdBytes: 10, windowSeconds: 180, observedSeconds: 2, policyVersion: 2, occurredAt: f.clock.now())
            #expect(try await store.recordTrafficAlert(event))
        }
        let app = AppIdentity(key: "signed:retained", name: "App")
        try await store.recordSample(day: day, increments: [UsageIncrement(identity: app, uploadedBytes: 2, downloadedBytes: 3)],
            interfaceIncrement: InterfaceUsage(day: day, uploadedBytes: 5, downloadedBytes: 8), category: category)
        try await store.saveRule(appKey: app.key, rule: QuotaRule(limitBytes: 100), category: category)
        _ = try await store.claimNotification(appKey: app.key, day: day, kind: .warning, ruleVersion: 1, category: category)
    }
    let extra = TrafficAlertEvent(category: .metered, day: day, kind: .applicationBurst,
        sourceKey: "exec:/extra", sourceName: "Extra", observedBytes: 12, thresholdBytes: 10,
        windowSeconds: 180, observedSeconds: 2, policyVersion: 2, occurredAt: f.clock.now())
    await #expect(throws: TrafficAlertError.eventLimit) { try await store.recordTrafficAlert(extra) }
    f.clock.advance(86_400)
    try await store.prunePreviousDays()
    for category in TrafficCategory.allCases {
        #expect(try await store.trafficAlertEvents(day: day, category: category).isEmpty)
        #expect(try await store.interfaceUsage(day: day, category: category) == nil)
        #expect(try await !store.hasApplicationUsage(day: day, category: category))
        #expect(try await store.deliveredNotifications(day: day, category: category).isEmpty)
        #expect(try await store.loadRules(category: category).count == 1)
        #expect(try await store.trafficAlertPolicy(category: category) == policy)
    }
    try await store.close()
}
