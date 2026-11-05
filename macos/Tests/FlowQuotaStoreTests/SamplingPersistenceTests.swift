import FlowQuotaCore
import Testing
@testable import FlowQuotaStore

struct SamplingPersistenceTests {
    @Test func duplicateRowsAddAndPersistWithoutClampingOrResettingRules() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        try await fixture.seed(store)
        try await store.recordUsage(appKey: "signed:app", day: fixture.day, uploadedBytes: 4, downloadedBytes: 7)
        let canonical = AppIdentity(key: "path:/caf\u{00E9}", name: "Café")
        try await store.recordSample(day: fixture.day, increments: [
            UsageIncrement(identity: AppIdentity(key: "signed:app", name: "Renamed"),
                           uploadedBytes: 100, downloadedBytes: 2),
            UsageIncrement(identity: canonical, uploadedBytes: 2, downloadedBytes: 3),
            UsageIncrement(identity: canonical, uploadedBytes: 5, downloadedBytes: 7),
            UsageIncrement(identity: AppIdentity(key: "zero", name: "Observed"),
                           uploadedBytes: 0, downloadedBytes: 0),
        ])
        try await store.close()
        let reopened = try fixture.open()
        let snapshots = try await reopened.snapshot(day: fixture.day)
        #expect(snapshots.count == 3)
        let existing = try #require(snapshots.first { $0.id == "signed:app" })
        #expect(existing.identity.name == "Renamed")
        #expect(existing.rule == (try QuotaRule(limitBytes: 100)))
        #expect(existing.usage.uploadedBytes == 104)
        #expect(existing.usage.downloadedBytes == 9)
        let added = try #require(snapshots.first { $0.id == canonical.key })
        #expect(added.identity == canonical)
        #expect(added.usage.uploadedBytes == 7)
        #expect(added.usage.downloadedBytes == 10)
        #expect(added.rule == nil)
        let zero = try #require(snapshots.first { $0.id == "zero" })
        #expect(zero.usage.totalBytes == 0)
        #expect(zero.rule == nil)
        #expect(try await reopened.snapshot(day: "2026-11-03").allSatisfy { $0.usage.totalBytes == 0 })
        try await reopened.close()
    }

    @Test func databaseFailureRollsBackNewIdentitiesRenamesAndUsage() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        try await fixture.seed(store)
        try await store.recordUsage(appKey: "signed:app", day: fixture.day, uploadedBytes: 4, downloadedBytes: 7)
        let db = try SQLiteConnection(path: fixture.path)
        try db.execute("""
            CREATE TRIGGER reject_sample BEFORE INSERT ON daily_usage
            WHEN NEW.app_key = 'reject'
            BEGIN SELECT RAISE(ABORT, 'injected sample failure'); END
            """)
        do {
            try await store.recordSample(day: fixture.day, increments: [
                UsageIncrement(identity: AppIdentity(key: "new", name: "New"), uploadedBytes: 1, downloadedBytes: 2),
                UsageIncrement(identity: AppIdentity(key: "signed:app", name: "Changed"),
                               uploadedBytes: 3, downloadedBytes: 4),
                UsageIncrement(identity: AppIdentity(key: "reject", name: "Rejected"),
                               uploadedBytes: 5, downloadedBytes: 6),
            ])
            Issue.record("Injected sample should fail")
        } catch let error as StoreError {
            guard case .sqlite = error else { throw error }
        }
        #expect(try db.scalar("SELECT COUNT(*) FROM applications") == 1)
        #expect(try db.scalar("SELECT COUNT(*) FROM daily_usage") == 1)
        let snapshots = try await store.snapshot(day: fixture.day)
        let app = try #require(snapshots.first)
        #expect(app.identity == AppIdentity(key: "signed:app", name: "Application"))
        #expect(app.usage.uploadedBytes == 4)
        #expect(app.usage.downloadedBytes == 7)
        #expect(app.rule == (try QuotaRule(limitBytes: 100)))
        try db.execute("DROP TRIGGER reject_sample")
        try await store.recordSample(day: fixture.day, increments: [
            UsageIncrement(identity: app.identity, uploadedBytes: 1, downloadedBytes: 0),
        ])
        #expect(try await store.snapshot(day: fixture.day).first?.usage.uploadedBytes == 5)
        try db.close()
        try await store.close()
    }

    @Test func invalidIdentitiesRollBackEarlierEntries() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        let canonical = AppIdentity(key: "path:/caf\u{00E9}", name: "Original")
        try await store.registerApplication(canonical)
        let invalidIdentities = [
            AppIdentity(key: "", name: "Empty key"),
            AppIdentity(key: " \n\t", name: "Blank key"),
            AppIdentity(key: "path:/bad\0suffix", name: "NUL key"),
            AppIdentity(key: "path:/cafe\u{0301}", name: "Decomposed key"),
            AppIdentity(key: "valid", name: ""),
            AppIdentity(key: "valid", name: " \n\t"),
            AppIdentity(key: "valid", name: "Bad\0name"),
        ]
        for invalid in invalidIdentities {
            await expectStoreError(.invalidIdentifier) {
                try await store.recordSample(day: fixture.day, increments: [
                    UsageIncrement(identity: AppIdentity(key: canonical.key, name: "Changed"),
                                   uploadedBytes: 3, downloadedBytes: 4),
                    UsageIncrement(identity: AppIdentity(key: "new", name: "New"),
                                   uploadedBytes: 1, downloadedBytes: 2),
                    UsageIncrement(identity: invalid, uploadedBytes: 0, downloadedBytes: 0),
                ])
            }
            let snapshots = try await store.snapshot(day: fixture.day)
            #expect(snapshots.count == 1)
            #expect(snapshots.first?.identity == canonical)
            #expect(snapshots.first?.usage.totalBytes == 0)
        }
        try await store.close()
    }

    @Test func invalidByteDeltasAndTheirSumRollBackTheBatch() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        let identity = AppIdentity(key: "new", name: "New")
        let invalid: [(Int64, Int64, StoreError)] = [
            (-1, 0, .invalidBytes), (0, -1, .invalidBytes),
            (.min, .max, .invalidBytes), (.max, 1, .overflow), (1, .max, .overflow),
        ]
        for (upload, download, error) in invalid {
            await expectStoreError(error) {
                try await store.recordSample(day: fixture.day, increments: [
                    UsageIncrement(identity: identity, uploadedBytes: 1, downloadedBytes: 2),
                    UsageIncrement(identity: identity, uploadedBytes: upload, downloadedBytes: download),
                ])
            }
            #expect(try await store.snapshot(day: fixture.day).isEmpty)
        }
        try await store.close()
    }

    @Test func cumulativeOverflowRollsBackIncludingNewApplications() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        try await fixture.seed(store, limit: nil)
        try await store.recordUsage(appKey: "signed:app", day: fixture.day, uploadedBytes: .max - 2, downloadedBytes: 1)
        await expectStoreError(.overflow) {
            try await store.recordSample(day: fixture.day, increments: [
                UsageIncrement(identity: AppIdentity(key: "new", name: "New"), uploadedBytes: 1, downloadedBytes: 2),
                UsageIncrement(identity: AppIdentity(key: "signed:app", name: "Changed"),
                               uploadedBytes: 1, downloadedBytes: 0),
                UsageIncrement(identity: AppIdentity(key: "signed:app", name: "Changed again"),
                               uploadedBytes: 0, downloadedBytes: 1),
            ])
        }
        let snapshots = try await store.snapshot(day: fixture.day)
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.identity.name == "Application")
        #expect(snapshots.first?.usage.uploadedBytes == Int64.max - 2)
        #expect(snapshots.first?.usage.downloadedBytes == 1)
        try await store.close()
    }

    @Test func sampleIncludesOutstandingLiabilitiesInOverflowCheck() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        try await fixture.seed(store, limit: nil)
        _ = try await store.reserveBudget(id: "maximum", appKey: "signed:app", day: fixture.day,
                                         bytes: .max, ruleVersion: 1, expiresAt: fixture.expiry)
        await expectStoreError(.overflow) {
            try await store.recordSample(day: fixture.day, increments: [
                UsageIncrement(identity: AppIdentity(key: "new", name: "New"), uploadedBytes: 1, downloadedBytes: 0),
                UsageIncrement(identity: AppIdentity(key: "signed:app", name: "Changed"),
                               uploadedBytes: 0, downloadedBytes: 1),
            ])
        }
        let snapshots = try await store.snapshot(day: fixture.day)
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.identity.name == "Application")
        #expect(snapshots.first?.usage.totalBytes == 0)
        let balance = try await store.budgetBalance(appKey: "signed:app", day: fixture.day)
        #expect(balance.outstandingBytes == .max)
        #expect(balance.chargedBytes == .max)
        try await store.close()
    }

    @Test func acceptsEmptyAndMaximumBatchRejectsOversizeWithoutWrites() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        try await store.recordSample(day: fixture.day, increments: [])
        #expect(try await store.snapshot(day: fixture.day).isEmpty)
        let maximum = (0..<4096).map { index in
            UsageIncrement(identity: AppIdentity(key: "app-\(index)", name: "App \(index)"),
                           uploadedBytes: 1, downloadedBytes: 2)
        }
        let oversize = maximum + [UsageIncrement(identity: AppIdentity(key: "extra", name: "Extra"),
                                                uploadedBytes: 0, downloadedBytes: 0)]
        await expectStoreError(.configuration("A sample may contain at most 4096 increments")) {
            try await store.recordSample(day: fixture.day, increments: oversize)
        }
        #expect(try await store.snapshot(day: fixture.day).isEmpty)
        try await store.recordSample(day: fixture.day, increments: maximum)
        let snapshots = try await store.snapshot(day: fixture.day)
        #expect(snapshots.count == 4096)
        #expect(snapshots.allSatisfy { $0.usage.uploadedBytes == 1 && $0.usage.downloadedBytes == 2 })
        try await store.close()
        await expectStoreError(.closed) {
            try await store.recordSample(day: fixture.day, increments: [])
        }
    }

    @Test func invalidDaysFailEvenForAnEmptySample() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        for day in ["", "2026-02-29", "2026-11-4", "2026-11-04\0", "0000-01-01"] {
            await expectStoreError(.invalidDay(day)) {
                try await store.recordSample(day: day, increments: [])
            }
        }
        #expect(try await store.snapshot(day: fixture.day).isEmpty)
        try await store.close()
    }
}
