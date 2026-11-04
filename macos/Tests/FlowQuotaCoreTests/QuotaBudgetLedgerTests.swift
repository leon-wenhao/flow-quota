import XCTest
@testable import FlowQuotaCore

@MainActor
final class QuotaBudgetLedgerTests: XCTestCase {
    private func ledger(limit: Int64? = 100, used: Int64 = 0, bound: Int = 1_024) throws -> QuotaBudgetLedger {
        try QuotaBudgetLedger(appKey: "signed.app", day: "2026-11-04",
                              rule: QuotaRule(limitBytes: limit), usedBytes: used,
                              maximumPendingReservations: bound)
    }

    private func grant(_ ledger: QuotaBudgetLedger, bytes: Int64) async throws -> BudgetReservation {
        let token = try await ledger.reserve(bytes: bytes)
        return try XCTUnwrap(token)
    }

    func testConcurrentReservationsCannotOverbookCap() async throws {
        let ledger = try ledger(limit: 1_000, used: 19)
        let grants = try await withThrowingTaskGroup(of: BudgetReservation?.self) { group in
            for _ in 0..<980 { group.addTask { try await ledger.reserve(bytes: 17) } }
            var result: [BudgetReservation] = []
            for try await token in group { if let token { result.append(token) } }
            return result
        }
        XCTAssertEqual(grants.reduce(Int64(0)) { $0 + $1.grantedBytes }, 981)
        var snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.usedBytes + snapshot.reservedBytes, 1_000)
        XCTAssertEqual(snapshot.availableBytes, 0)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for grant in grants { group.addTask { _ = try await ledger.reconcile(grant, consumedBytes: grant.grantedBytes) } }
            try await group.waitForAll()
        }
        snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.usedBytes, 1_000)
        XCTAssertEqual(snapshot.reservedBytes, 0)
        XCTAssertEqual(snapshot.pendingReservations, 0)
    }

    func testNinetyEightConcurrentConnectionsReconcileRepeatedChunks() async throws {
        let ledger = try ledger(limit: 1_000)
        let consumed = try await withThrowingTaskGroup(of: Int64.self) { group in
            for _ in 0..<98 {
                group.addTask {
                    var total: Int64 = 0
                    for _ in 0..<10 {
                        guard let token = try await ledger.reserve(bytes: 13) else { break }
                        total += token.grantedBytes
                        try await ledger.reconcile(token, consumedBytes: token.grantedBytes)
                    }
                    return total
                }
            }
            var total: Int64 = 0
            for try await bytes in group { total += bytes }
            return total
        }
        let snapshot = await ledger.snapshot()
        XCTAssertEqual(consumed, 1_000)
        XCTAssertEqual(snapshot.usedBytes, consumed)
        XCTAssertEqual(snapshot.reservedBytes, 0)
    }

    func testReconcileReleaseAndForfeit() async throws {
        let ledger = try ledger()
        let first = try await grant(ledger, bytes: 80)
        var snapshot = try await ledger.reconcile(first, consumedBytes: 30)
        XCTAssertEqual(snapshot.usedBytes, 30)
        XCTAssertEqual(snapshot.availableBytes, 70)
        let second = try await grant(ledger, bytes: 40)
        snapshot = try await ledger.release(second)
        XCTAssertEqual(snapshot.availableBytes, 70)
        let third = try await grant(ledger, bytes: 100)
        XCTAssertEqual(third.grantedBytes, 70)
        snapshot = try await ledger.forfeit(third)
        XCTAssertEqual(snapshot.usedBytes, 100)
        XCTAssertEqual(snapshot.availableBytes, 0)
    }

    func testInvalidAndDuplicateReportsCannotChangeBalance() async throws {
        let ledger = try ledger()
        let token = try await grant(ledger, bytes: 70)
        for invalid in [Int64(-1), 71, .max] {
            do {
                try await ledger.reconcile(token, consumedBytes: invalid)
                XCTFail("Accepted invalid actuals")
            } catch { XCTAssertEqual(error as? QuotaBudgetError, .invalidConsumption) }
        }
        var snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.reservedBytes, 70)
        XCTAssertEqual(snapshot.usedBytes, 0)
        try await ledger.reconcile(token, consumedBytes: 10)
        do {
            try await ledger.release(token)
            XCTFail("Accepted duplicate settlement")
        } catch { XCTAssertEqual(error as? QuotaBudgetError, .unknownReservation) }
        snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.usedBytes, 10)
        XCTAssertEqual(snapshot.availableBytes, 90)
    }

    func testRuleUpdatesKeepUsageAndPendingOldIdentity() async throws {
        let ledger = try ledger(used: 40)
        let token = try await grant(ledger, bytes: 50)
        var snapshot = try await ledger.updateRule(QuotaRule(limitBytes: 30, version: 2))
        XCTAssertEqual(snapshot.usedBytes, 40)
        XCTAssertEqual(snapshot.reservedBytes, 50)
        XCTAssertEqual(snapshot.availableBytes, 0)
        let current = await ledger.isCurrent(token)
        XCTAssertFalse(current)
        XCTAssertEqual(token.identity.ruleVersion, 1)
        let denied = try await ledger.reserve(bytes: 1)
        XCTAssertNil(denied)
        snapshot = try await ledger.reconcile(token, consumedBytes: 20)
        XCTAssertEqual(snapshot.usedBytes, 60)
        snapshot = try await ledger.updateRule(QuotaRule(limitBytes: 100, version: 3))
        XCTAssertEqual(snapshot.availableBytes, 40)
        let newToken = try await grant(ledger, bytes: 100)
        XCTAssertEqual(newToken.identity.ruleVersion, 3)
        XCTAssertEqual(newToken.grantedBytes, 40)
    }

    func testDisableAndReenableNeverResetCountersOrHolds() async throws {
        let ledger = try ledger(used: 20)
        let old = try await grant(ledger, bytes: 30)
        try await ledger.updateRule(QuotaRule(limitBytes: nil, version: 2))
        let extra = try await grant(ledger, bytes: 100)
        var snapshot = try await ledger.updateRule(QuotaRule(limitBytes: 100, version: 3))
        XCTAssertEqual(snapshot.usedBytes, 20)
        XCTAssertEqual(snapshot.reservedBytes, 130)
        XCTAssertEqual(snapshot.availableBytes, 0)
        try await ledger.release(extra)
        snapshot = try await ledger.forfeit(old)
        XCTAssertEqual(snapshot.usedBytes, 50)
        XCTAssertEqual(snapshot.availableBytes, 50)
    }

    func testStaleOrConflictingVersionFailsAndIdenticalUpdateIsIdempotent() async throws {
        let ledger = try ledger()
        let next = try QuotaRule(limitBytes: 50, version: 2)
        let before = try await ledger.updateRule(next)
        let repeated = try await ledger.updateRule(next)
        XCTAssertEqual(before, repeated)
        for rule in [try QuotaRule(limitBytes: 100, version: 1), try QuotaRule(limitBytes: 100, version: 2)] {
            do {
                try await ledger.updateRule(rule)
                XCTFail("Accepted invalid version")
            } catch {
                XCTAssertEqual(error as? QuotaBudgetError, rule.version == 1 ? .staleRuleVersion : .conflictingRuleVersion)
            }
        }
        let after = await ledger.snapshot()
        XCTAssertEqual(before, after)
    }

    func testForeignDayAppAndRuleLedgerCannotSettleReceipts() async throws {
        let original = try ledger()
        let token = try await grant(original, bytes: 50)
        for (app, day, revision) in [("signed.app", "2026-11-05", Int64(1)),
                                     ("other.app", "2026-11-04", 1), ("signed.app", "2026-11-04", 2)] {
            let rule = try QuotaRule(limitBytes: 100, version: revision)
            let other = try QuotaBudgetLedger(appKey: app, day: day, rule: rule, usedBytes: 0)
            do {
                try await other.release(token)
                XCTFail("Cross-bucket settlement")
            } catch { XCTAssertEqual(error as? QuotaBudgetError, .unknownReservation) }
            let snapshot = await other.snapshot()
            XCTAssertEqual(snapshot.availableBytes, 100)
        }
        let originalState = await original.snapshot()
        XCTAssertEqual(originalState.reservedBytes, 50)
    }

    func testLateOldReceiptCannotReclaimNewRevisionReservations() async throws {
        let ledger = try ledger(used: 20)
        let old = try await grant(ledger, bytes: 30)
        try await ledger.updateRule(QuotaRule(limitBytes: 150, version: 2))
        let current = try await grant(ledger, bytes: 80)
        var snapshot = try await ledger.reconcile(old, consumedBytes: 10)
        XCTAssertEqual(snapshot.usedBytes, 30)
        XCTAssertEqual(snapshot.reservedBytes, 80)
        XCTAssertEqual(snapshot.availableBytes, 40)
        do {
            try await ledger.release(old)
            XCTFail("Old receipt reclaimed a current grant")
        } catch { XCTAssertEqual(error as? QuotaBudgetError, .unknownReservation) }
        let forged = BudgetReservation(id: current.id, identity: old.identity, grantedBytes: current.grantedBytes)
        do {
            try await ledger.release(forged)
            XCTFail("Wrong-revision receipt released a current grant")
        } catch { XCTAssertEqual(error as? QuotaBudgetError, .unknownReservation) }
        snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.usedBytes, 30)
        XCTAssertEqual(snapshot.reservedBytes, 80)
        XCTAssertEqual(snapshot.availableBytes, 40)
        let stillCurrent = await ledger.isCurrent(current)
        XCTAssertTrue(stillCurrent)
        try await ledger.forfeit(current)
    }

    func testUnlimitedAndMaxCounterNeverOverflow() async throws {
        let ledger = try ledger(limit: nil, used: .max - 1)
        let token = try await grant(ledger, bytes: .max)
        XCTAssertEqual(token.grantedBytes, 1)
        let snapshot = try await ledger.forfeit(token)
        XCTAssertEqual(snapshot.usedBytes, .max)
        let denied = try await ledger.reserve(bytes: 1)
        XCTAssertNil(denied)
    }

    func testBoundedPendingTokensAndInvalidRequests() async throws {
        let ledger = try ledger(bound: 1)
        let token = try await grant(ledger, bytes: 10)
        do {
            _ = try await ledger.reserve(bytes: 1)
            XCTFail("Exceeded memory bound")
        } catch { XCTAssertEqual(error as? QuotaBudgetError, .tooManyReservations) }
        try await ledger.release(token)
        for invalid in [Int64(0), -1] {
            do {
                _ = try await ledger.reserve(bytes: invalid)
                XCTFail("Accepted invalid request")
            } catch { XCTAssertEqual(error as? QuotaBudgetError, .invalidRequest) }
        }
        XCTAssertThrowsError(try self.ledger(used: -1))
        XCTAssertThrowsError(try self.ledger(bound: 0))
    }
}
