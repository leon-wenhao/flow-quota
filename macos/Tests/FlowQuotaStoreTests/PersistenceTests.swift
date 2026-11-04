import Foundation
import Testing
@testable import FlowQuotaStore
import FlowQuotaCore

struct PersistenceTests {
    @Test func reopenRulesUsageAndNotifications() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try QuotaStore(path: fixture.path) // Exercise exact production initializer.
        try await fixture.seed(store)
        try await store.registerApplication(AppIdentity(key: "signed:app", name: "Renamed ' application"))
        try await store.registerApplication(AppIdentity(key: "no-rule", name: "Unmonitored"))
        try await store.recordUsage(appKey: "signed:app", day: fixture.day, uploadedBytes: 4, downloadedBytes: 7)
        try await store.recordUsage(appKey: "signed:app", day: fixture.day, uploadedBytes: 5, downloadedBytes: 6)
        #expect(try await store.claimNotification(appKey: "signed:app", day: fixture.day, kind: .warning, ruleVersion: 1))
        #expect(try await !store.claimNotification(appKey: "signed:app", day: fixture.day, kind: .warning, ruleVersion: 1))
        try await store.close()
        let reopened = try fixture.open()
        let rules = try await reopened.loadRules()
        #expect(rules["signed:app"] == (try QuotaRule(limitBytes: 100)))
        let snapshots = try await reopened.snapshot(day: fixture.day)
        let app = try #require(snapshots.first(where: { $0.id == "signed:app" }))
        #expect(app.identity.name == "Renamed ' application")
        #expect(app.usage.uploadedBytes == 9)
        #expect(app.usage.downloadedBytes == 13)
        #expect(snapshots.first(where: { $0.id == "no-rule" })?.rule == nil)
        #expect(try await !reopened.claimNotification(appKey: "signed:app", day: fixture.day, kind: .warning, ruleVersion: 1))
        #expect(try await reopened.claimNotification(appKey: "signed:app", day: fixture.day, kind: .blocked, ruleVersion: 1))
        try await reopened.close()
        try await reopened.close()
        await expectStoreError(.closed) { try await reopened.loadRules() }
    }

    @Test func ruleUpdatesRejectStaleAndEqualConflicts() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let unlimited = try QuotaRule(limitBytes: nil, warningPercent: 90, version: 2)
        try await store.saveRule(appKey: "signed:app", rule: unlimited)
        try await store.saveRule(appKey: "signed:app", rule: unlimited)
        await expectStoreError(.staleRuleVersion) {
            try await store.saveRule(appKey: "signed:app", rule: QuotaRule(limitBytes: 500, version: 1))
        }
        await expectStoreError(.staleRuleVersion) {
            try await store.saveRule(appKey: "signed:app", rule: QuotaRule(limitBytes: 500, version: 2))
        }
        await expectStoreError(.unknownApplication("absent")) {
            try await store.saveRule(appKey: "absent", rule: unlimited)
        }
        await expectStoreError(.staleRuleVersion) {
            try await store.claimNotification(appKey: "signed:app", day: fixture.day, kind: .warning, ruleVersion: 1)
        }
        #expect(try await store.claimNotification(appKey: "signed:app", day: fixture.day, kind: .warning, ruleVersion: 2))
        #expect(try await store.loadRules()["signed:app"] == unlimited)
        try await store.close()
    }

    @Test func invalidInputAndOverflowLeaveUsageIntact() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        try await fixture.seed(store, limit: nil)
        for day in ["2026-02-29", "2026-04-31", "0000-01-01", "2026-1-01", "2026-01-01'", "2026-13-01"] {
            await expectStoreError(.invalidDay(day)) { try await store.snapshot(day: day) }
        }
        #expect(try await store.snapshot(day: "2000-02-29").count == 1)
        await expectStoreError(.invalidIdentifier) {
            try await store.registerApplication(AppIdentity(key: "bad\0key", name: "Application"))
        }
        await expectStoreError(.invalidBytes) {
            try await store.recordUsage(appKey: "signed:app", day: fixture.day, uploadedBytes: -1, downloadedBytes: 0)
        }
        await expectStoreError(.unknownApplication("missing")) {
            try await store.recordUsage(appKey: "missing", day: fixture.day, uploadedBytes: 1, downloadedBytes: 0)
        }
        try await store.recordUsage(appKey: "signed:app", day: fixture.day, uploadedBytes: .max - 2, downloadedBytes: 1)
        await expectStoreError(.overflow) {
            try await store.recordUsage(appKey: "signed:app", day: fixture.day, uploadedBytes: 1, downloadedBytes: 1)
        }
        await expectStoreError(.overflow) {
            try await store.recordUsage(appKey: "signed:app", day: fixture.day, uploadedBytes: .max, downloadedBytes: 1)
        }
        let usage = try #require(try await store.snapshot(day: fixture.day).first).usage
        #expect(usage.uploadedBytes == .max - 2)
        #expect(usage.downloadedBytes == 1)
        try await store.close()
    }

    @Test func boundIdentifiersNeverBecomeSQL() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        let key = "a'); DROP TABLE applications;--"
        try await fixture.seed(store, key: key)
        try await store.recordUsage(appKey: key, day: fixture.day, uploadedBytes: 1, downloadedBytes: 2)
        #expect(try await store.snapshot(day: fixture.day).first?.usage.totalBytes == 3)
        try await store.close()
    }
}
