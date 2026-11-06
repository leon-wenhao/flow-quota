import Foundation
import Testing
import FlowQuotaCore
@testable import FlowQuotaStore

struct ClashMinutePersistenceTests {
    let kernel = AppIdentity(key: "exec:/Library/Application Support/clash-verge-service/cores/verge-mihomo", name: "Mihomo")
    func source(_ id: String, download: Int64, identified: Bool = true) -> ClashUsageSource {
        ClashUsageSource(id: id, name: id + "（Clash）", uploadedBytes: 0, downloadedBytes: download, identified: identified)
    }
    func record(_ store: QuotaStore, _ f: StoreFixture, download: Int64, second: Double = 0) async throws {
        try await store.recordSample(day: f.day, increments: [UsageIncrement(identity: kernel,
            uploadedBytes: 0, downloadedBytes: download)], applicationObservedAt: f.clock.now().addingTimeInterval(second),
            observedApplicationKeys: [kernel.key])
    }
    func query(_ f: StoreFixture) -> ApplicationTimelineQuery {
        ApplicationTimelineQuery(day: f.day, category: .metered, start: f.clock.now(), end: f.clock.now().addingTimeInterval(300))
    }

    @Test func dailyTimelineAlertAndRestartKeepAllEightHundredMegabytes() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        let store = try f.open()
        try await record(store, f, download: 800_000_000)
        try await store.recordClashSources([source("虎牙", download: 300_000_000), source("YouTube", download: 300_000_000),
            source("unknown", download: 90_000_000, identified: false)], at: f.clock.now(), category: .metered)
        let daily = try #require(try await store.dailyClashBreakdown(day: f.day, category: .metered))
        #expect(daily.sources.count == 3)
        #expect(daily.sources.reduce(0) { $0 + $1.downloadedBytes } == 800_000_000)
        #expect(daily.sources.first { !$0.identified }?.downloadedBytes == 200_000_000)
        let timeline = try await store.sourceTimeline(query(f))
        #expect(timeline.sourcesResolved == true)
        #expect(timeline.buckets.allSatisfy { $0.appKey == nil })
        #expect(timeline.buckets.reduce(0) { $0 + $1.downloadedBytes } == 800_000_000)
        let alert = try await store.dailyAlertApplications(day: f.day, category: .metered, observedAt: f.clock.now())
        #expect(alert.items.count == 1)
        #expect(alert.displaySources == daily.sources)
        #expect(try await store.dailyClashBreakdown(day: f.day, category: .ordinary) == nil)
        try await store.close()
        let reopened = try f.open()
        #expect(try await reopened.dailyClashBreakdown(day: f.day, category: .metered) == daily)
        #expect(try await reopened.sourceTimeline(query(f)) == timeline)
        try await reopened.close()
    }

    @Test func legacyMissingMinutesAndContradictoryMinutesStayUnknown() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        let store = try f.open()
        // Existing daily-only usage has no minute evidence and is not backfilled.
        try await store.recordSample(day: f.day, increments: [UsageIncrement(identity: kernel, uploadedBytes: 0, downloadedBytes: 100)])
        try await record(store, f, download: 400)
        try await record(store, f, download: 300, second: 60)
        try await store.recordClashSources([source("YouTube", download: 500)], at: f.clock.now(), category: .metered)
        try await store.recordClashSources([source("YouTube", download: 100)], at: f.clock.now().addingTimeInterval(60), category: .metered)
        let daily = try #require(try await store.dailyClashBreakdown(day: f.day, category: .metered))
        #expect(daily.sources.first { !$0.identified }?.downloadedBytes == 700)
        #expect(daily.sources.first { $0.identified }?.downloadedBytes == 100)
        #expect(daily.notice != nil)
        let timeline = try await store.sourceTimeline(query(f))
        #expect(timeline.buckets.first { $0.clashSourceID == ClashUsageBreakdown.unknownID }?.downloadedBytes == 600)
        try await store.close()
    }

    @Test func batchFailureRollsBackAndCapacityCannotDropParentBytes() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        let store = try f.open()
        try await record(store, f, download: 800)
        let sources = (0..<128).map { source("site:\($0)", download: 1) }
        try await store.recordClashSources(sources, at: f.clock.now(), category: .metered)
        do {
            try await store.recordClashSources([sources[0], source("excess", download: 100)], at: f.clock.now(), category: .metered)
            Issue.record("Expected capacity error")
        } catch {}
        #expect(try await store.clashMinuteRows(day: f.day, category: .metered).count == 128)
        let result = try #require(try await store.dailyClashBreakdown(day: f.day, category: .metered))
        #expect(result.sources.first { $0.id == "site:0" }?.downloadedBytes == 1)
        #expect(result.sources.first { !$0.identified }?.downloadedBytes == 672)
        let db = try SQLiteConnection(path: f.path)
        try db.execute("""
            CREATE TRIGGER fail_clash BEFORE INSERT ON clash_source_usage_minutes
            WHEN NEW.source_id = 'fault' BEGIN SELECT RAISE(ABORT, 'injected'); END
            """)
        do {
            try await store.recordClashSources([source("ok", download: 1), source("fault", download: 1)],
                at: f.clock.now(), category: .ordinary)
            Issue.record("Expected rollback")
        } catch {}
        #expect(try await store.clashMinuteRows(day: f.day, category: .ordinary).isEmpty)
        try db.close(); try await store.close()
    }

    @Test func minuteRowCapacityRollsBackExistingUpdatesAndIndexedReadsRemainBounded() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        let store = try f.open()
        let db = try SQLiteConnection(path: f.path)
        let start = Int64(f.clock.now().timeIntervalSince1970 * 1_000)
        try db.execute("""
            WITH RECURSIVE cells(n) AS (SELECT 0 UNION ALL SELECT n + 1 FROM cells WHERE n < 32767)
            INSERT INTO clash_source_usage_minutes
            SELECT ?, 'metered', ? + (n / 128) * 60000, 'site:' || (n % 128), 'Site ' || (n % 128), 1, 0, 1, 1 FROM cells
            """, [.text(f.day), .integer(start)])
        do {
            let existing = ClashUsageSource(id: "site:0", name: "Site 0", uploadedBytes: 0, downloadedBytes: 10)
            try await store.recordClashSources([existing], at: f.clock.now().addingTimeInterval(256 * 60), category: .metered)
            Issue.record("Expected minute capacity error")
        } catch {}
        #expect(try db.scalar("SELECT COUNT(*) FROM clash_source_usage_minutes") == 32768)
        let began = ContinuousClock.now
        let rows = try await store.clashMinuteRows(day: f.day, category: .metered, start: start, end: start + 3_600_000)
        #expect(rows.count == 7_680)
        print("Clash minute fixture: 32768 persisted cells, 128 sources × 60 minute query: \(began.duration(to: .now))")
        try db.close(); try await store.close()
    }

    @Test func migrationIsAtomicNoBackfillAndRetentionIncludesDateRollback() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        let initial = try f.open()
        try await record(initial, f, download: 800)
        try await initial.close()
        let db = try SQLiteConnection(path: f.path)
        try db.execute("DROP TABLE clash_source_usage_minutes")
        try db.execute("CREATE TABLE clash_source_usage_minutes (evidence TEXT)")
        try db.execute("INSERT INTO clash_source_usage_minutes VALUES ('retain')")
        try db.execute("PRAGMA user_version = 8")
        #expect(throws: StoreError.self) { try f.open() }
        #expect(try db.scalar("PRAGMA user_version") == 8)
        #expect(try db.query("SELECT evidence FROM clash_source_usage_minutes", row: { $0.text(0) }) == ["retain"])
        try db.execute("DROP TABLE clash_source_usage_minutes")
        let store = try f.open()
        #expect(try db.scalar("PRAGMA user_version") == 9)
        #expect(try await store.clashMinuteRows(day: f.day, category: .metered).isEmpty)
        try await store.recordClashSources([source("YouTube", download: 300)], at: f.clock.now(), category: .metered)
        let old = f.day
        f.clock.advance(-86_400)
        try await store.prunePreviousDays()
        #expect(try await store.clashMinuteRows(day: old, category: .metered).isEmpty)
        #expect(try db.scalar("PRAGMA secure_delete") == 1)
        #expect(try db.query("PRAGMA integrity_check", row: { $0.text(0) }) == ["ok"])
        let plan = try db.query("""
            EXPLAIN QUERY PLAN SELECT source_id FROM clash_source_usage_minutes
            WHERE day = ? AND category = ? AND minute_start_ms >= ? AND minute_start_ms < ?
            """, [.text(f.day), .text("metered"), .integer(0), .integer(Int64.max)]) { $0.text(3) }
        #expect(plan.contains { $0.contains("SEARCH") && $0.contains("INDEX") })
        #expect(!plan.contains { $0.contains("SCAN") })
        try db.close(); try await store.close()
    }
}
