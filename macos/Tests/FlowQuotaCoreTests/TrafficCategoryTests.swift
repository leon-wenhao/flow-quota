import Foundation
import Testing
@testable import FlowQuotaCore

@Test func classificationKeepsEvidenceButSharesOnlyMeteredCategory() throws {
    #expect(NetworkState.hotspot.trafficCategory == .metered)
    #expect(NetworkState.expensive.trafficCategory == .metered)
    #expect(NetworkState.ordinary.trafficCategory == .ordinary)
    #expect(NetworkState.unknown.trafficCategory == nil)
    #expect(NetworkState.ordinary.countsTraffic)
    #expect(!NetworkState.unknown.countsTraffic)
    let identity = try QuotaIdentity(appKey: "signed:app", day: "2026-11-05", ruleVersion: 1)
    let metered = QuotaNotificationKey(identity: identity, kind: .warning)
    let ordinary = QuotaNotificationKey(identity: identity, kind: .warning, category: .ordinary)
    #expect(metered != ordinary)
    let rule = try QuotaRule(limitBytes: 100)
    let usage = DailyUsage(appKey: identity.appKey, day: identity.day, uploadedBytes: 80, downloadedBytes: 0)
    let next = try QuotaTransitions.evaluate(identity: identity, rule: rule, usage: usage,
        network: .ordinary, delivered: [metered], category: .ordinary)
    #expect(next.notification == ordinary)
    let legacy = Data("{\"identity\":{\"appKey\":\"signed:app\",\"day\":\"2026-11-05\",\"ruleVersion\":1},\"kind\":\"warning\"}".utf8)
    #expect(try JSONDecoder().decode(QuotaNotificationKey.self, from: legacy) == metered)
    #expect(try JSONDecoder().decode(QuotaNotificationKey.self, from: JSONEncoder().encode(ordinary)) == ordinary)
}
