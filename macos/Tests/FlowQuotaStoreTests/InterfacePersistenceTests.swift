import Foundation
import Testing
import FlowQuotaCore
@testable import FlowQuotaStore

struct InterfacePersistenceTests {
    @Test func unknownZeroIndependentAppAttributionAndReopen() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        let app = AppIdentity(key: "app", name: "Application")
        #expect(try await store.interfaceUsage(day: fixture.day) == nil)
        try await store.recordSample(day: fixture.day, increments: [
            UsageIncrement(identity: app, uploadedBytes: 900, downloadedBytes: 100)
        ])
        #expect(try await store.interfaceUsage(day: fixture.day) == nil)
        try await store.recordSample(day: fixture.day, increments: [], interfaceIncrement:
            InterfaceUsage(day: fixture.day, uploadedBytes: 0, downloadedBytes: 0))
        #expect(try await store.interfaceUsage(day: fixture.day)?.totalBytes == 0)
        try await store.recordSample(day: fixture.day, increments: [], interfaceIncrement:
            InterfaceUsage(day: fixture.day, uploadedBytes: 11, downloadedBytes: 22))
        try await store.recordSample(day: fixture.day, increments: [
            UsageIncrement(identity: app, uploadedBytes: 10, downloadedBytes: 20)
        ], interfaceIncrement: InterfaceUsage(day: fixture.day, uploadedBytes: 3, downloadedBytes: 4))
        try await store.recordSample(day: fixture.day, increments: [
            UsageIncrement(identity: app, uploadedBytes: 1, downloadedBytes: 2)
        ])
        let expected = InterfaceUsage(day: fixture.day, uploadedBytes: 14, downloadedBytes: 26)
        #expect(try await store.interfaceUsage(day: fixture.day) == expected)
        #expect(try await store.snapshot(day: fixture.day).first?.usage.totalBytes == 1_033)
        try await store.close()
        let reopened = try fixture.open()
        #expect(try await reopened.interfaceUsage(day: fixture.day) == expected)
        #expect(try await reopened.interfaceUsage(day: "2026-11-05") == nil)
        try await reopened.close()
        await expectStoreError(.closed) { try await reopened.interfaceUsage(day: fixture.day) }
    }

    @Test func interfaceOnlyCreatesNoApplicationAndSerializesConcurrentSamples() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    try await store.recordSample(day: fixture.day, increments: [], interfaceIncrement:
                        InterfaceUsage(day: fixture.day, uploadedBytes: 1, downloadedBytes: 2))
                }
            }
            try await group.waitForAll()
        }
        #expect(try await store.interfaceUsage(day: fixture.day) ==
            InterfaceUsage(day: fixture.day, uploadedBytes: 100, downloadedBytes: 200))
        #expect(try await store.snapshot(day: fixture.day).isEmpty)
        #expect(try await store.loadRules().isEmpty)
        try await store.close()
    }

    @Test func invalidInterfaceDeltaRollsBackApplicationWrites() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        let app = AppIdentity(key: "new", name: "New application")
        for (upload, download, error) in [
            (Int64(-1), Int64(0), StoreError.invalidBytes),
            (0, -1, .invalidBytes), (.max, 1, .overflow)
        ] {
            await expectStoreError(error) {
                try await store.recordSample(day: fixture.day, increments: [
                    UsageIncrement(identity: app, uploadedBytes: 1, downloadedBytes: 2)
                ], interfaceIncrement: InterfaceUsage(day: fixture.day, uploadedBytes: upload, downloadedBytes: download))
            }
            #expect(try await store.snapshot(day: fixture.day).isEmpty)
            #expect(try await store.interfaceUsage(day: fixture.day) == nil)
        }
        try await store.close()
    }

    @Test func dayMismatchAndMalformedDayNeverWrite() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        let appDelta = UsageIncrement(identity: AppIdentity(key: "new", name: "New"),
                                      uploadedBytes: 1, downloadedBytes: 2)
        await expectStoreError(.configuration("Interface sample day must match batch day")) {
            try await store.recordSample(day: fixture.day, increments: [appDelta], interfaceIncrement:
                InterfaceUsage(day: "2026-11-05", uploadedBytes: 1, downloadedBytes: 2))
        }
        for day in ["", "2026-02-29", "2026-04-31", "0000-01-01", "2026-11-04\0"] {
            await expectStoreError(.invalidDay(day)) { try await store.interfaceUsage(day: day) }
            await expectStoreError(.invalidDay(day)) {
                try await store.recordSample(day: fixture.day, increments: [appDelta], interfaceIncrement:
                    InterfaceUsage(day: day, uploadedBytes: 1, downloadedBytes: 2))
            }
        }
        #expect(try await store.snapshot(day: fixture.day).isEmpty)
        #expect(try await store.interfaceUsage(day: fixture.day) == nil)
        try await store.close()
    }

    @Test func cumulativeDirectionAndTotalOverflowRollBackWholeBatch() async throws {
        for (initialUpload, initialDownload, upload, download) in [
            (Int64.max, Int64(0), Int64(1), Int64(0)),
            (0, .max, 0, 1), (.max - 1, 1, 0, 1)
        ] {
            let fixture = try StoreFixture()
            defer { fixture.cleanup() }
            let store = try fixture.open()
            let initial = InterfaceUsage(day: fixture.day, uploadedBytes: initialUpload, downloadedBytes: initialDownload)
            try await store.recordSample(day: fixture.day, increments: [], interfaceIncrement: initial)
            await expectStoreError(.overflow) {
                try await store.recordSample(day: fixture.day, increments: [
                    UsageIncrement(identity: AppIdentity(key: "new", name: "New"), uploadedBytes: 1, downloadedBytes: 2)
                ], interfaceIncrement: InterfaceUsage(day: fixture.day, uploadedBytes: upload, downloadedBytes: download))
            }
            #expect(try await store.interfaceUsage(day: fixture.day) == initial)
            #expect(try await store.snapshot(day: fixture.day).isEmpty)
            try await store.close()
        }
    }

    @Test func appFailurePreservesExistingInterfaceTotal() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        let initial = InterfaceUsage(day: fixture.day, uploadedBytes: 10, downloadedBytes: 20)
        try await store.recordSample(day: fixture.day, increments: [], interfaceIncrement: initial)
        await expectStoreError(.invalidBytes) {
            try await store.recordSample(day: fixture.day, increments: [
                UsageIncrement(identity: AppIdentity(key: "new", name: "New"), uploadedBytes: 1, downloadedBytes: 2),
                UsageIncrement(identity: AppIdentity(key: "bad", name: "Bad"), uploadedBytes: -1, downloadedBytes: 0)
            ], interfaceIncrement: InterfaceUsage(day: fixture.day, uploadedBytes: 100, downloadedBytes: 200))
        }
        #expect(try await store.interfaceUsage(day: fixture.day) == initial)
        #expect(try await store.snapshot(day: fixture.day).isEmpty)
        try await store.close()
    }

    @Test func pruningInterfaceDaysIsIndependentOfUnresolvedAppLeases() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let store = try fixture.open()
        try await fixture.seed(store)
        let oldDay = fixture.day
        _ = try await store.reserveBudget(id: "uncertain", appKey: "signed:app", day: oldDay,
                                          bytes: 10, ruleVersion: 1, expiresAt: fixture.expiry)
        try await store.recordSample(day: oldDay, increments: [], interfaceIncrement:
            InterfaceUsage(day: oldDay, uploadedBytes: 1, downloadedBytes: 2))
        try await store.prunePreviousDays()
        #expect(try await store.interfaceUsage(day: oldDay)?.totalBytes == 3)
        fixture.clock.advance(86_400)
        let today = fixture.day
        let current = InterfaceUsage(day: today, uploadedBytes: 4, downloadedBytes: 5)
        try await store.recordSample(day: today, increments: [], interfaceIncrement: current)
        try await store.prunePreviousDays()
        #expect(try await store.interfaceUsage(day: oldDay) == nil)
        #expect(try await store.interfaceUsage(day: today) == current)
        #expect(try await store.budgetBalance(appKey: "signed:app", day: oldDay).outstandingBytes == 10)
        #expect(try await store.loadRules()["signed:app"]?.version == 1)
        try await store.close()
    }
}
