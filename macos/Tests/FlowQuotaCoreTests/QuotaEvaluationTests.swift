import XCTest
@testable import FlowQuotaCore

final class QuotaEvaluationTests: XCTestCase {
    private let app = "signed.app"
    private let day = "2026-11-04"

    private func usage(_ bytes: Int64, upload: Int64 = 0) -> DailyUsage {
        DailyUsage(appKey: app, day: day, uploadedBytes: upload, downloadedBytes: bytes)
    }

    func testThresholdAndCapBoundariesUseBothDirections() throws {
        let rule = try QuotaRule(limitBytes: 101)
        for (bytes, state) in [(80, QuotaStatus.withinLimit), (81, .warning), (100, .warning), (101, .blocked), (102, .blocked)] {
            let value = try QuotaEvaluator.evaluate(rule: rule, usage: usage(Int64(bytes)), network: .hotspot)
            XCTAssertEqual(value.status, state)
            XCTAssertEqual(value.warningThresholdBytes, 81)
            XCTAssertEqual(value.remainingBytes, max(0, 101 - Int64(bytes)))
        }
        XCTAssertEqual(try QuotaEvaluator.evaluate(rule: rule, usage: usage(61, upload: 40), network: .hotspot).status, .blocked)
        let single = try QuotaRule(limitBytes: 1, warningPercent: 1)
        XCTAssertEqual(try QuotaEvaluator.evaluate(rule: single, usage: usage(0), network: .hotspot).status, .withinLimit)
        XCTAssertEqual(try QuotaEvaluator.evaluate(rule: single, usage: usage(1), network: .hotspot).status, .blocked)
    }

    func testScopeUnlimitedAndUnavailableRemainDistinct() throws {
        let rule = try QuotaRule(limitBytes: 10)
        for network in [NetworkState.unknown] {
            let value = try QuotaEvaluator.evaluate(rule: rule, usage: usage(20), network: network)
            XCTAssertEqual(value.status, .unknownNetwork)
            XCTAssertFalse(value.countsTraffic)
            XCTAssertNil(value.remainingBytes)
        }
        XCTAssertEqual(try QuotaEvaluator.evaluate(rule: rule, usage: usage(20), network: .ordinary).status, .blocked)
        XCTAssertEqual(try QuotaEvaluator.evaluate(rule: nil, usage: usage(20), network: .ordinary).status, .unlimited)
        XCTAssertEqual(try QuotaEvaluator.evaluate(rule: nil, usage: usage(20), network: .hotspot).status, .unlimited)
        XCTAssertEqual(try QuotaEvaluator.evaluate(rule: QuotaRule(limitBytes: nil), usage: usage(20), network: .hotspot).status, .unlimited)
        XCTAssertEqual(try QuotaEvaluator.evaluate(rule: nil, usage: nil, network: .hotspot).status, .usageUnavailable)
        XCTAssertThrowsError(try QuotaEvaluator.evaluate(rule: rule, usage: usage(-1), network: .hotspot))
        XCTAssertThrowsError(try QuotaEvaluator.evaluate(rule: rule, usage: usage(1, upload: -1), network: .ordinary))
    }

    func testOverflowSaturatesAndThresholdDoesNotOverflow() throws {
        let counters = usage(1, upload: .max)
        XCTAssertEqual(counters.totalBytes, .max)
        let rule = try QuotaRule(limitBytes: .max, warningPercent: 99)
        let result = try QuotaEvaluator.evaluate(rule: rule, usage: counters, network: .hotspot)
        XCTAssertEqual(result.status, .blocked)
        XCTAssertEqual(result.warningThresholdBytes, 9_131_138_316_486_228_049)
    }

    func testWarningBlockDedupSurvivesReconnectAndCodableRoundTrip() throws {
        let rule = try QuotaRule(limitBytes: 100)
        let identity = try QuotaIdentity(appKey: app, day: day, ruleVersion: 1)
        let warning = try QuotaTransitions.evaluate(identity: identity, rule: rule, usage: usage(80), network: .hotspot)
        XCTAssertEqual(warning.notification?.kind, .warning)
        var delivered: Set<QuotaNotificationKey> = [try XCTUnwrap(warning.notification)]
        let data = try JSONEncoder().encode(delivered)
        delivered = try JSONDecoder().decode(Set<QuotaNotificationKey>.self, from: data)
        XCTAssertNil(try QuotaTransitions.evaluate(identity: identity, rule: rule, usage: usage(90), network: .hotspot, delivered: delivered).notification)
        let block = try QuotaTransitions.evaluate(identity: identity, rule: rule, usage: usage(100), network: .hotspot, delivered: delivered)
        XCTAssertEqual(block.notification?.kind, .blocked)
        delivered.insert(try XCTUnwrap(block.notification))
        XCTAssertNil(try QuotaTransitions.evaluate(identity: identity, rule: rule, usage: usage(100), network: .ordinary, delivered: delivered).notification)
        XCTAssertNil(try QuotaTransitions.evaluate(identity: identity, rule: rule, usage: usage(100), network: .hotspot, delivered: delivered).notification)
        XCTAssertNil(try QuotaTransitions.evaluate(identity: identity, rule: rule, usage: usage(80), network: .hotspot, delivered: delivered).notification)
    }

    func testRuleUpdatesAndIdentityBoundaries() throws {
        let identity = try QuotaIdentity(appKey: app, day: day, ruleVersion: 2)
        let lowered = try QuotaRule(limitBytes: 50, version: 2)
        XCTAssertEqual(try QuotaTransitions.evaluate(identity: identity, rule: lowered, usage: usage(80), network: .hotspot).notification?.kind, .blocked)
        let raised = try QuotaRule(limitBytes: 200, version: 3)
        XCTAssertEqual(try QuotaEvaluator.evaluate(rule: raised, usage: usage(80), network: .hotspot).status, .withinLimit)
        XCTAssertThrowsError(try QuotaTransitions.evaluate(identity: identity, rule: raised, usage: usage(80), network: .hotspot))
        let wrongDay = DailyUsage(appKey: app, day: "2026-11-03", uploadedBytes: 0, downloadedBytes: 80)
        XCTAssertThrowsError(try QuotaTransitions.evaluate(identity: identity, rule: lowered, usage: wrongDay, network: .hotspot))
        let wrongApp = DailyUsage(appKey: "other.app", day: day, uploadedBytes: 0, downloadedBytes: 80)
        XCTAssertThrowsError(try QuotaTransitions.evaluate(identity: identity, rule: lowered, usage: wrongApp, network: .hotspot))
    }
}
