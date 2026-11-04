import Foundation
import Testing
@testable import FlowQuotaStore
import FlowQuotaCore

struct BudgetLeaseTests {
    @Test func burstAcrossConnectionsAndDuplicateSettlement() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        try await fixture.seed(store)
        try await store.recordUsage(appKey: "signed:app", day: fixture.day, uploadedBytes: 10, downloadedBytes: 6)
        let other = try fixture.open()
        let ids = try await withThrowingTaskGroup(of: String?.self) { group in
            for index in 0..<80 {
                group.addTask {
                    do {
                        let owner = index.isMultiple(of: 2) ? store : other
                        _ = try await owner.reserveBudget(id: "burst-\(index)", appKey: "signed:app", day: fixture.day,
                            bytes: 7, ruleVersion: 1, expiresAt: fixture.expiry)
                        return "burst-\(index)"
                    } catch StoreError.quotaExceeded { return nil }
                }
            }
            var successes: [String] = []
            for try await id in group { if let id { successes.append(id) } }
            return successes
        }
        #expect(ids.count == 12) // 16 actual + 12 * 7 reserved = 100.
        #expect(try await store.budgetBalance(appKey: "signed:app", day: fixture.day).chargedBytes == 100)
        let settledID = try #require(ids.first)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    _ = try await (index.isMultiple(of: 2) ? store : other).settleBudget(
                        id: settledID, uploadedBytes: 2, downloadedBytes: 3)
                }
            }
            try await group.waitForAll()
        }
        let balance = try await store.budgetBalance(appKey: "signed:app", day: fixture.day)
        #expect(balance.usedBytes == 21)
        #expect(balance.outstandingBytes == 77)
        #expect(balance.chargedBytes == 98)
        await expectStoreError(.leaseConflict) {
            try await store.settleBudget(id: settledID, uploadedBytes: 1, downloadedBytes: 4)
        }
        await expectStoreError(.leaseInactive) {
            try await store.reserveBudget(id: settledID, appKey: "signed:app", day: fixture.day,
                                          bytes: 7, ruleVersion: 1, expiresAt: fixture.expiry)
        }
        try await other.close()
        try await store.close()
    }

    @Test func reopenRetainsLiabilityAndIdempotency() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let grant = try await store.reserveBudget(id: "lease", appKey: "signed:app", day: fixture.day,
                                                  bytes: 80, ruleVersion: 1, expiresAt: fixture.expiry)
        #expect(try await store.reserveBudget(id: "lease", appKey: "signed:app", day: fixture.day,
                                              bytes: 80, ruleVersion: 1, expiresAt: fixture.expiry) == grant)
        try await store.close()
        let reopened = try fixture.open()
        #expect(try await reopened.budgetBalance(appKey: "signed:app", day: fixture.day).outstandingBytes == 80)
        await expectStoreError(.quotaExceeded) {
            try await reopened.reserveBudget(id: "excess", appKey: "signed:app", day: fixture.day,
                                              bytes: 21, ruleVersion: 1, expiresAt: fixture.expiry)
        }
        await expectStoreError(.invalidBytes) {
            try await reopened.settleBudget(id: "lease", uploadedBytes: 80, downloadedBytes: 1)
        }
        #expect(try await reopened.budgetBalance(appKey: "signed:app", day: fixture.day).chargedBytes == 80)
        let receipt = try await reopened.settleBudget(id: "lease", uploadedBytes: 15, downloadedBytes: 25)
        try await reopened.close()
        let again = try fixture.open()
        #expect(try await again.settleBudget(id: "lease", uploadedBytes: 15, downloadedBytes: 25) == receipt)
        #expect(try await again.budgetBalance(appKey: "signed:app", day: fixture.day).usedBytes == 40)
        try await again.close()
    }

    @Test func expiredAndOldDayBudgetsNeverReissue() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let oldDay = fixture.day
        let oldExpiry = fixture.expiry
        try await store.recordUsage(appKey: "signed:app", day: oldDay, uploadedBytes: 10, downloadedBytes: 0)
        _ = try await store.reserveBudget(id: "unknown", appKey: "signed:app", day: oldDay,
                                          bytes: 90, ruleVersion: 1, expiresAt: oldExpiry)
        fixture.clock.advance(61)
        await expectStoreError(.leaseInactive) {
            try await store.settleBudget(id: "unknown", uploadedBytes: 0, downloadedBytes: 0)
        }
        await expectStoreError(.invalidExpiry) {
            try await store.reserveBudget(id: "unknown", appKey: "signed:app", day: oldDay,
                                          bytes: 90, ruleVersion: 1, expiresAt: oldExpiry)
        }
        await expectStoreError(.quotaExceeded) {
            try await store.reserveBudget(id: "replacement", appKey: "signed:app", day: oldDay,
                                          bytes: 1, ruleVersion: 1, expiresAt: fixture.expiry)
        }
        fixture.clock.advance(86_400)
        try await store.prunePreviousDays()
        #expect(try await store.budgetBalance(appKey: "signed:app", day: oldDay).chargedBytes == 100)
        await expectStoreError(.inactiveDay) {
            try await store.reserveBudget(id: "old", appKey: "signed:app", day: oldDay,
                                          bytes: 1, ruleVersion: 1, expiresAt: fixture.expiry)
        }
        await expectStoreError(.leaseConflict) {
            try await store.reserveBudget(id: "unknown", appKey: "signed:app", day: fixture.day,
                                          bytes: 90, ruleVersion: 1, expiresAt: fixture.expiry)
        }
        _ = try await store.reserveBudget(id: "new-day", appKey: "signed:app", day: fixture.day,
                                          bytes: 100, ruleVersion: 1, expiresAt: fixture.expiry)
        try await store.close()
        let reopened = try fixture.open()
        #expect(try await reopened.budgetBalance(appKey: "signed:app", day: oldDay).outstandingBytes == 90)
        try await reopened.close()
    }

    @Test func ruleReductionAndLeaseValidation() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        try await fixture.seed(store)
        _ = try await store.reserveBudget(id: "old-rule", appKey: "signed:app", day: fixture.day,
                                          bytes: 80, ruleVersion: 1, expiresAt: fixture.expiry)
        try await store.saveRule(appKey: "signed:app", rule: QuotaRule(limitBytes: 50, version: 2))
        await expectStoreError(.staleRuleVersion) {
            try await store.reserveBudget(id: "old-rule", appKey: "signed:app", day: fixture.day,
                                          bytes: 80, ruleVersion: 1, expiresAt: fixture.expiry)
        }
        await expectStoreError(.quotaExceeded) {
            try await store.reserveBudget(id: "after-reduction", appKey: "signed:app", day: fixture.day,
                                          bytes: 1, ruleVersion: 2, expiresAt: fixture.expiry)
        }
        // Final measured counters remain valid after a rule edit; cannot lose reality.
        _ = try await store.settleBudget(id: "old-rule", uploadedBytes: 20, downloadedBytes: 10)
        _ = try await store.reserveBudget(id: "remaining", appKey: "signed:app", day: fixture.day,
                                          bytes: 20, ruleVersion: 2, expiresAt: fixture.expiry)
        await expectStoreError(.leaseConflict) {
            try await store.reserveBudget(id: "remaining", appKey: "signed:app", day: fixture.day,
                                          bytes: 19, ruleVersion: 2, expiresAt: fixture.expiry)
        }
        await expectStoreError(.invalidExpiry) {
            try await store.reserveBudget(id: "tomorrow", appKey: "signed:app", day: fixture.day,
                                          bytes: 1, ruleVersion: 2, expiresAt: fixture.expiry.addingTimeInterval(86_400))
        }
        await expectStoreError(.unknownLease("absent")) {
            try await store.settleBudget(id: "absent", uploadedBytes: 0, downloadedBytes: 0)
        }
        try await store.close()
    }

    @Test func liabilityOverflowAndFailedSettlementRollback() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        try await fixture.seed(store, limit: nil)
        _ = try await store.reserveBudget(id: "maximum", appKey: "signed:app", day: fixture.day,
                                          bytes: .max, ruleVersion: 1, expiresAt: fixture.expiry)
        await expectStoreError(.overflow) {
            try await store.recordUsage(appKey: "signed:app", day: fixture.day, uploadedBytes: 1, downloadedBytes: 0)
        }
        await expectStoreError(.overflow) {
            try await store.reserveBudget(id: "overflow", appKey: "signed:app", day: fixture.day,
                                          bytes: 1, ruleVersion: 1, expiresAt: fixture.expiry)
        }
        // Fault injection after daily_usage is written proves the settlement is atomic.
        let connection = try SQLiteConnection(path: fixture.path)
        try connection.execute("""
            CREATE TRIGGER reject_settlement BEFORE UPDATE ON budget_leases
            BEGIN SELECT RAISE(ABORT, 'injected settlement failure'); END
            """)
        do {
            _ = try await store.settleBudget(id: "maximum", uploadedBytes: 5, downloadedBytes: 5)
            Issue.record("Injected settlement should fail")
        } catch let error as StoreError {
            guard case .sqlite = error else { throw error }
        }
        let balance = try await store.budgetBalance(appKey: "signed:app", day: fixture.day)
        #expect(balance.usedBytes == 0)
        #expect(balance.outstandingBytes == .max)
        try connection.close()
        try await store.close()
    }
}
