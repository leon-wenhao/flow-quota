import Foundation
import Testing
import FlowQuotaCore
@testable import FlowQuotaStore

struct TrafficAlertPolicyTests {
    @Test func defaultsExactRetryMonotonicRevisionAndRestart() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        #expect(try await store.trafficAlertPolicy() == .initial)
        try await store.saveTrafficAlertPolicy(.initial)
        let next = try alertPolicy()
        try await store.saveTrafficAlertPolicy(next)
        try await store.saveTrafficAlertPolicy(next)
        await expectStoreError(.staleTrafficAlertPolicy) { try await store.saveTrafficAlertPolicy(.initial) }
        let conflicting = try alertPolicy(burst: 101)
        await expectStoreError(.staleTrafficAlertPolicy) { try await store.saveTrafficAlertPolicy(conflicting) }
        #expect(try await store.trafficAlertPolicy() == next)
        let maximum = try alertPolicy(version: Int64.max, daily: Int64.max, burst: nil, app: nil)
        try await store.saveTrafficAlertPolicy(maximum)
        try await store.saveTrafficAlertPolicy(maximum)
        await expectStoreError(.staleTrafficAlertPolicy) {
            try await store.saveTrafficAlertPolicy(alertPolicy(version: Int64.max, daily: nil, burst: nil, app: nil))
        }
        try await store.close()
        let reopened = try fixture.open()
        #expect(try await reopened.trafficAlertPolicy() == maximum)
        try await reopened.close()
    }

    @Test func decodedPoliciesRevalidateEveryFieldWithoutWriting() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        let next = try alertPolicy()
        for (field, value) in [("dailyInterfaceBytes", 0), ("interfaceBurstBytes", -1),
                               ("applicationBurstBytes", 0), ("windowSeconds", 59), ("windowSeconds", 901),
                               ("cooldownSeconds", 59), ("cooldownSeconds", 86401), ("version", 0)] {
            let invalid = try decodedMutation(next, field: field, replacement: value)
            await expectAlertError(.invalidPolicy) { try await store.saveTrafficAlertPolicy(invalid) }
            #expect(try await store.trafficAlertPolicy() == .initial)
        }
        try await store.close()
    }

    @Test func twoConnectionsSerializeConflictingRevisions() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let first = try fixture.open(), second = try fixture.open()
        let a = try alertPolicy(burst: 123), b = try alertPolicy(burst: 456)
        let successes = await withTaskGroup(of: Bool.self) { group in
            group.addTask { do { try await first.saveTrafficAlertPolicy(a); return true } catch { return false } }
            group.addTask { do { try await second.saveTrafficAlertPolicy(b); return true } catch { return false } }
            var result = 0
            for await success in group { if success { result += 1 } }
            return result
        }
        #expect(successes == 1)
        let saved = try await first.trafficAlertPolicy()
        #expect(saved == a || saved == b)
        #expect(try await second.trafficAlertPolicy() == saved)
        try await first.close(); try await second.close()
    }
}
