import Foundation
import FlowQuotaCore
import Testing
@testable import FlowQuotaStore

struct InterfaceMinuteTests {
    @Test func measuredZeroAndMinuteBoundariesAreDurableAndCategoryScoped() async throws {
        let f = try StoreFixture()
        defer { f.cleanup() }
        let store = try f.open()
        let baseline = InterfaceUsage(day: f.day, uploadedBytes: 0, downloadedBytes: 0)
        try await store.recordSample(day: f.day, increments: [], interfaceIncrement: baseline)
        #expect(try await store.interfaceUsageMinutes(day: f.day, category: .metered).isEmpty)
        for (seconds, upload, download, category) in [
            (0.0, Int64(0), Int64(0), TrafficCategory.metered),
            (2.0, 10, 20, .metered), (59.0, 1, 2, .metered),
            (60.0, 0, 0, .metered), (60.0, 100, 200, .ordinary)
        ] {
            try await store.recordSample(day: f.day, increments: [], interfaceIncrement:
                InterfaceUsage(day: f.day, uploadedBytes: upload, downloadedBytes: download),
                category: category, interfaceObservedAt: f.clock.now().addingTimeInterval(seconds))
        }
        let minutes = try await store.interfaceUsageMinutes(day: f.day, category: .metered)
        #expect(minutes.count == 2)
        #expect(minutes.map(\.sampleCount) == [3, 1])
        #expect(minutes.map(\.uploadedBytes) == [11, 0])
        #expect(minutes.map(\.downloadedBytes) == [22, 0])
        #expect(minutes[1].minuteStartMilliseconds - minutes[0].minuteStartMilliseconds == 60_000)
        #expect(try await store.interfaceUsageMinutes(day: f.day, category: .ordinary).first?.uploadedBytes == 100)
        try await store.close()
        let reopened = try f.open()
        #expect(try await reopened.interfaceUsageMinutes(day: f.day, category: .metered) == minutes)
        #expect(try await reopened.interfaceUsage(day: f.day)?.totalBytes == 33)
        try await reopened.close()
    }

    @Test func invalidObservationAndMissingIncrementRollBackApplicationAndInterfaceWrites() async throws {
        let f = try StoreFixture()
        defer { f.cleanup() }
        let store = try f.open()
        let delta = InterfaceUsage(day: f.day, uploadedBytes: 1, downloadedBytes: 2)
        for date in [f.clock.now().addingTimeInterval(86_400), Date(timeIntervalSince1970: .nan)] {
            do {
                try await store.recordSample(day: f.day, increments: [UsageIncrement(
                    identity: AppIdentity(key: "new", name: "New"), uploadedBytes: 1, downloadedBytes: 2)],
                    interfaceIncrement: delta, interfaceObservedAt: date)
                Issue.record("Expected invalid observation")
            } catch {}
        }
        await expectStoreError(.configuration("Minute observation requires an interface increment")) {
            try await store.recordSample(day: f.day, increments: [], interfaceObservedAt: f.clock.now())
        }
        #expect(try await store.interfaceUsage(day: f.day) == nil)
        #expect(try await store.snapshot(day: f.day).isEmpty)
        #expect(try await store.interfaceUsageMinutes(day: f.day, category: .metered).isEmpty)
        try await store.close()
    }

    @Test func minuteOverflowRollsBackDailyAndApplicationChanges() async throws {
        let f = try StoreFixture()
        defer { f.cleanup() }
        let store = try f.open()
        let db = try SQLiteConnection(path: f.path)
        let minute = Int64(f.clock.now().timeIntervalSince1970 / 60) * 60_000
        // Fault injection isolates a minute overflow from the daily total check.
        try db.execute("INSERT INTO interface_usage_minutes VALUES (?, 'metered', ?, ?, 0, 1)",
                       [.text(f.day), .integer(minute), .integer(.max)])
        await expectStoreError(.overflow) {
            try await store.recordSample(day: f.day, increments: [UsageIncrement(
                identity: AppIdentity(key: "new", name: "New"), uploadedBytes: 1, downloadedBytes: 2)],
                interfaceIncrement: InterfaceUsage(day: f.day, uploadedBytes: 1, downloadedBytes: 0),
                interfaceObservedAt: f.clock.now())
        }
        #expect(try await store.interfaceUsage(day: f.day) == nil)
        #expect(try await store.snapshot(day: f.day).isEmpty)
        #expect(try await store.interfaceUsageMinutes(day: f.day, category: .metered).first?.uploadedBytes == .max)
        try db.close()
        try await store.close()
    }

    @Test func dayCleanupRemovesMinutesFromBothCategoriesAndKeepsCurrentDay() async throws {
        let f = try StoreFixture()
        defer { f.cleanup() }
        let store = try f.open()
        let oldDay = f.day
        for category in TrafficCategory.allCases {
            try await store.recordSample(day: f.day, increments: [], interfaceIncrement:
                InterfaceUsage(day: f.day, uploadedBytes: 1, downloadedBytes: 2), category: category,
                interfaceObservedAt: f.clock.now())
        }
        f.clock.advance(86_400)
        try await store.recordSample(day: f.day, increments: [], interfaceIncrement:
            InterfaceUsage(day: f.day, uploadedBytes: 3, downloadedBytes: 4), category: .ordinary,
            interfaceObservedAt: f.clock.now())
        try await store.prunePreviousDays()
        for category in TrafficCategory.allCases {
            #expect(try await store.interfaceUsageMinutes(day: oldDay, category: category).isEmpty)
        }
        #expect(try await store.interfaceUsageMinutes(day: f.day, category: .ordinary).first?.uploadedBytes == 3)
        try await store.close()
    }

    @Test func v5UpgradePreservesLedgersPoliciesAndNeverBackfillsMinutes() async throws {
        let f = try StoreFixture()
        defer { f.cleanup() }
        let initial = try f.open()
        try await f.seed(initial)
        for category in TrafficCategory.allCases {
            try await initial.recordSample(day: f.day, increments: [UsageIncrement(
                identity: AppIdentity(key: "signed:app", name: "Application"), uploadedBytes: 5, downloadedBytes: 6)],
                interfaceIncrement: InterfaceUsage(day: f.day, uploadedBytes: 100, downloadedBytes: 200), category: category)
        }
        let policy = try TrafficAlertPolicy(dailyInterfaceBytes: 987, interfaceBurstBytes: nil,
            applicationBurstBytes: nil, windowSeconds: 300, cooldownSeconds: 600, version: 17)
        try await initial.saveTrafficAlertPolicy(policy)
        try await initial.close()
        let old = try SQLiteConnection(path: f.path)
        try old.execute("DROP TABLE interface_usage_minutes")
        try old.execute("DROP TABLE application_usage_minutes")
        try old.execute("PRAGMA user_version = 5")
        try old.close()
        let upgraded = try f.open()
        for category in TrafficCategory.allCases {
            #expect(try await upgraded.interfaceUsageMinutes(day: f.day, category: category).isEmpty)
            #expect(try await upgraded.interfaceUsage(day: f.day, category: category)?.totalBytes == 300)
            #expect(try await upgraded.snapshot(day: f.day, category: category).first?.usage.totalBytes == 11)
        }
        #expect(try await upgraded.trafficAlertPolicy() == policy)
        #expect(try await upgraded.trafficAlertPolicy(category: .ordinary) == .disabled)
        #expect(try await upgraded.loadRules()["signed:app"]?.limitBytes == 100)
        let db = try SQLiteConnection(path: f.path)
        #expect(try db.scalar("PRAGMA user_version") == 7)
        #expect(try db.query("PRAGMA integrity_check", row: { $0.text(0) }) == ["ok"])
        #expect(try db.query("PRAGMA foreign_key_check", row: { $0.text(0) }).isEmpty)
        try db.close()
        try await upgraded.close()
    }

    @Test func v6FailureRetainsVersionAndConflictingTableThenCanRetry() async throws {
        let f = try StoreFixture()
        defer { f.cleanup() }
        let initial = try f.open()
        try await initial.close()
        let old = try SQLiteConnection(path: f.path)
        try old.execute("DROP TABLE interface_usage_minutes")
        try old.execute("CREATE TABLE interface_usage_minutes (evidence TEXT)")
        try old.execute("INSERT INTO interface_usage_minutes VALUES ('retain')")
        try old.execute("DROP TABLE application_usage_minutes")
        try old.execute("PRAGMA user_version = 5")
        #expect(throws: StoreError.self) { try f.open() }
        #expect(try old.scalar("PRAGMA user_version") == 5)
        #expect(try old.query("SELECT evidence FROM interface_usage_minutes", row: { $0.text(0) }) == ["retain"])
        try old.execute("DROP TABLE interface_usage_minutes") // Remove injected collision only.
        try old.close()
        let retried = try f.open()
        #expect(try await retried.interfaceUsageMinutes(day: f.day, category: .metered).isEmpty)
        try await retried.close()
    }

    @Test func schemaRejectsInvalidMinuteCountersAndCategories() async throws {
        let f = try StoreFixture()
        defer { f.cleanup() }
        let store = try f.open()
        let db = try SQLiteConnection(path: f.path)
        for fields in [
            "'bad', 'ordinary', 60000, 1, 2, 1",
            "'2026-11-04', 'mixed', 60000, 1, 2, 1",
            "'2026-11-04', 'ordinary', 60001, 1, 2, 1",
            "'2026-11-04', 'ordinary', 0, 1, 2, 1",
            "'2026-11-04', 'ordinary', 60000, -1, 2, 1",
            "'2026-11-04', 'ordinary', 60000, 1.5, 2, 1",
            "'2026-11-04', 'ordinary', 60000, 9223372036854775807, 1, 1",
            "'2026-11-04', 'ordinary', 60000, 1, 2, 0"
        ] {
            #expect(throws: StoreError.self) { try db.execute("INSERT INTO interface_usage_minutes VALUES (\(fields))") }
        }
        #expect(try db.scalar("SELECT COUNT(*) FROM interface_usage_minutes") == 0)
        try db.close()
        try await store.close()
    }

    @Test func dayCategoryReadUsesCompositeIndexWithoutTemporarySort() async throws {
        let f = try StoreFixture()
        defer { f.cleanup() }
        let store = try f.open()
        let db = try SQLiteConnection(path: f.path)
        let midnight = Int64(f.calendar.startOfDay(for: f.clock.now()).timeIntervalSince1970 * 1_000)
        try db.transaction {
            for offset in 0..<1_440 {
                try db.execute("INSERT INTO interface_usage_minutes VALUES (?, 'ordinary', ?, 1, 2, 1)",
                    [.text(f.day), .integer(midnight + Int64(offset) * 60_000)])
            }
        }
        let plan = try db.query("""
            EXPLAIN QUERY PLAN SELECT minute_start_ms, uploaded_bytes, downloaded_bytes, sample_count
            FROM interface_usage_minutes WHERE day = ? AND category = ? ORDER BY minute_start_ms
            """, [.text(f.day), .text("ordinary")]) { $0.text(3) }
        #expect(plan.contains { $0.contains("SEARCH") && $0.contains("INDEX") })
        #expect(!plan.contains { $0.contains("TEMP B-TREE") || $0.contains("SCAN") })
        #expect(try await store.interfaceUsageMinutes(day: f.day, category: .ordinary).count == 1_440)
        print("Minute summary query plan: \(plan)")
        try db.close()
        try await store.close()
    }
}
