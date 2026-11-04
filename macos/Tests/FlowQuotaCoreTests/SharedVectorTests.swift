import Foundation
import XCTest
@testable import FlowQuotaCore

@MainActor
final class SharedVectorTests: XCTestCase {
    private func fixtureURL() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "quota-v1", withExtension: "json", subdirectory: "Fixtures"))
    }

    private func vectors() throws -> QuotaVectors {
        let fixture = try JSONDecoder().decode(QuotaVectors.self, from: Data(contentsOf: fixtureURL()))
        XCTAssertEqual(fixture.schemaVersion, 1)
        return fixture
    }

    private func bytes(_ text: String) throws -> Int64 {
        try XCTUnwrap(Int64(text), "Invalid Int64 fixture value: \(text)")
    }

    func testBundledVectorsMatchCanonicalBytes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let canonical = root.appendingPathComponent("shared/test-vectors/quota-v1.json")
        XCTAssertEqual(try Data(contentsOf: fixtureURL()), try Data(contentsOf: canonical),
                       "Run python3 shared/test-vectors/sync-fixtures.py after canonical changes")
    }

    func testSharedDecimalConversions() throws {
        for vector in try vectors().conversions {
            if let expectedError = vector.expectedError {
                XCTAssertThrowsError(try DecimalBytes.parse(vector.input, unit: vector.unit), vector.id) {
                    XCTAssertEqual(($0 as? DecimalByteError).map { String(describing: $0) }, expectedError, vector.id)
                }
            } else {
                XCTAssertEqual(try DecimalBytes.parse(vector.input, unit: vector.unit),
                               try bytes(XCTUnwrap(vector.expectedBytes)), vector.id)
            }
        }
    }

    func testSharedLocalDays() throws {
        for vector in try vectors().days {
            let date = try XCTUnwrap(ISO8601DateFormatter().date(from: vector.instant))
            let zone = try XCTUnwrap(TimeZone(identifier: vector.timeZone))
            XCTAssertEqual(try LocalDay.key(for: date, in: zone), vector.expectedDay, vector.id)
        }
    }

    func testSharedEvaluations() throws {
        for vector in try vectors().evaluations {
            let rule = try vector.hasRule ? QuotaRule(limitBytes: vector.limitBytes.map(bytes),
                                                      warningPercent: vector.warningPercent) : nil
            var usage: DailyUsage?
            if let up = vector.uploadedBytes, let down = vector.downloadedBytes {
                usage = try DailyUsage(appKey: "signed.app", day: "2026-11-04",
                                       uploadedBytes: bytes(up), downloadedBytes: bytes(down))
            }
            if let expectedError = vector.expectedError {
                XCTAssertThrowsError(try QuotaEvaluator.evaluate(rule: rule, usage: usage, network: vector.network)) {
                    XCTAssertEqual(($0 as? QuotaEvaluationError).map { String(describing: $0) }, expectedError, vector.id)
                }
            } else {
                let value = try QuotaEvaluator.evaluate(rule: rule, usage: usage, network: vector.network)
                XCTAssertEqual(value.status.rawValue, vector.expectedStatus, vector.id)
                XCTAssertEqual(value.countsTraffic, vector.network == .hotspot, vector.id)
                XCTAssertEqual(value.remainingBytes, try vector.expectedRemainingBytes.map(bytes), vector.id)
                XCTAssertEqual(value.warningThresholdBytes, try vector.expectedThresholdBytes.map(bytes), vector.id)
            }
        }
    }

    func testSharedNotificationTransitions() throws {
        for vector in try vectors().notifications {
            let identity = try QuotaIdentity(appKey: vector.appKey, day: vector.day, ruleVersion: vector.ruleVersion)
            let rule = try QuotaRule(limitBytes: vector.limitBytes.map(bytes),
                                     warningPercent: vector.warningPercent, version: vector.ruleVersion)
            let usage = try DailyUsage(appKey: vector.appKey, day: vector.day,
                                       uploadedBytes: bytes(vector.uploadedBytes), downloadedBytes: bytes(vector.downloadedBytes))
            let result = try QuotaTransitions.evaluate(identity: identity, rule: rule, usage: usage,
                                                       network: vector.network, delivered: vector.delivered)
            XCTAssertEqual(result.notification?.kind, vector.expectedNotification, vector.id)
            if let notification = result.notification { XCTAssertEqual(notification.identity, identity, vector.id) }
        }
    }

    func testSharedBudgetSequences() async throws {
        for vector in try vectors().budgets {
            let rule = try QuotaRule(limitBytes: vector.limitBytes.map(bytes))
            let ledger = try QuotaBudgetLedger(appKey: "signed.app", day: "2026-11-04", rule: rule,
                                               usedBytes: bytes(vector.usedBytes))
            var tokens: [String: BudgetReservation] = [:]
            for step in vector.steps {
                switch step.operation {
                case "reserve":
                    let token = try await ledger.reserve(bytes: bytes(XCTUnwrap(step.bytes)))
                    XCTAssertEqual(token?.grantedBytes, try step.expectedGrantedBytes.map(bytes), vector.id)
                    if let token { tokens[try XCTUnwrap(step.token)] = token }
                case "update":
                    let next = try QuotaRule(limitBytes: step.limitBytes.map(bytes), version: XCTUnwrap(step.version))
                    try await ledger.updateRule(next)
                case "release", "reconcile", "forfeit":
                    let name = try XCTUnwrap(step.token)
                    let token = try XCTUnwrap(tokens.removeValue(forKey: name))
                    if step.operation == "release" {
                        try await ledger.release(token)
                    } else if step.operation == "forfeit" {
                        try await ledger.forfeit(token)
                    } else {
                        try await ledger.reconcile(token, consumedBytes: bytes(XCTUnwrap(step.bytes)))
                    }
                default:
                    XCTFail("Unknown fixture operation: \(step.operation)")
                }
                let snapshot = await ledger.snapshot()
                XCTAssertEqual(snapshot.usedBytes, try bytes(step.expectedUsedBytes), vector.id)
                XCTAssertEqual(snapshot.reservedBytes, try bytes(step.expectedReservedBytes), vector.id)
                XCTAssertEqual(snapshot.availableBytes, try bytes(step.expectedAvailableBytes), vector.id)
                XCTAssertEqual(snapshot.pendingReservations, tokens.count, vector.id)
            }
        }
    }
}
