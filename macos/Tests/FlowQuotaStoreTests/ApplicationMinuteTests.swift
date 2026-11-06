import Foundation
import FlowQuotaCore
import Testing
@testable import FlowQuotaStore

struct ApplicationMinuteTests {
    private func query(_ f: StoreFixture, category: TrafficCategory = .metered,
                       appKey: String? = nil, hours: Int = 1) -> ApplicationTimelineQuery {
        ApplicationTimelineQuery(day: f.day, category: category, start: f.clock.now(),
            end: f.clock.now().addingTimeInterval(Double(hours * 3_600)), appKey: appKey)
    }

    private func record(_ store: QuotaStore, _ f: StoreFixture, key: String = "app:a", upload: Int64 = 0,
                        download: Int64 = 0, seconds: Double = 0, category: TrafficCategory = .metered,
                        measured: Bool = true) async throws {
        try await store.recordSample(day: f.day, increments: [UsageIncrement(identity: AppIdentity(key: key, name: key),
            uploadedBytes: upload, downloadedBytes: download)], category: category,
            applicationObservedAt: measured ? f.clock.now().addingTimeInterval(seconds) : nil,
            observedApplicationKeys: measured ? [key] : [])
    }

    @Test func baselinesZeroBoundariesCategoryAndRestartStayDistinct() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        let store = try f.open()
        try await record(store, f, measured: false)
        #expect(try await store.applicationTimeline(query(f)).buckets.isEmpty)
        try await record(store, f) // measured zero
        try await record(store, f, upload: 2, download: 3, seconds: 299)
        try await record(store, f, upload: 5, seconds: 300)
        try await record(store, f, download: 100, category: .ordinary)
        let rows = try await store.applicationTimeline(query(f)).buckets
        #expect(rows.count == 2)
        #expect(rows.map(\.sampleCount) == [2, 1])
        #expect(rows.map(\.uploadedBytes) == [2, 5])
        #expect(rows.map(\.downloadedBytes) == [3, 0])
        #expect(try await store.applicationTimeline(query(f, category: .ordinary)).buckets.first?.downloadedBytes == 100)
        try await store.close()
        let reopened = try f.open()
        #expect(try await reopened.applicationTimeline(query(f)).buckets == rows)
        try await reopened.close()
    }

    @Test func topTenTailAndSingleAppQueryRetainAllBytes() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        let store = try f.open()
        for index in 1...15 { try await record(store, f, key: "app:\(index)", upload: Int64(index), download: 10) }
        let rows = try await store.applicationTimeline(query(f)).buckets
        #expect(rows.count == 11)
        #expect(Set(rows.compactMap(\.appKey)) == Set((6...15).map { "app:\($0)" }))
        #expect(rows.first { $0.appKey == nil }?.uploadedBytes == 15)
        #expect(rows.first { $0.appKey == nil }?.downloadedBytes == 50)
        #expect(rows.reduce(0) { $0 + $1.uploadedBytes } == 120)
        let specific = try await store.applicationTimeline(query(f, appKey: "app:1"))
        #expect(specific.buckets.count == 1)
        #expect(specific.buckets.first?.appKey == "app:1")
        #expect(specific.buckets.first?.uploadedBytes == 1)
        #expect(try await store.applicationTimeline(query(f, appKey: "app:absent")).buckets.isEmpty)
        try await store.close()
    }

    @Test func invalidObservationAndOverflowRollBackDailyAndMinuteWrites() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        let store = try f.open()
        try await record(store, f, upload: Int64.max)
        await expectStoreError(.overflow) { try await record(store, f, download: 1) }
        let db = try SQLiteConnection(path: f.path)
        #expect(try db.scalar("SELECT uploaded_bytes FROM application_usage_minutes") == Int64.max)
        #expect(try db.scalar("SELECT sample_count FROM application_usage_minutes") == 1)
        #expect(try await store.snapshot(day: f.day).first?.usage.downloadedBytes == 0)
        do {
            try await store.recordSample(day: f.day, increments: [], applicationObservedAt: f.clock.now(),
                                         observedApplicationKeys: ["not-in-batch"])
            Issue.record("Expected identity validation")
        } catch {}
        do {
            try await record(store, f, key: "app:invalid", seconds: 86_400)
            Issue.record("Expected cross-day validation")
        } catch {}
        #expect(try db.scalar("SELECT COUNT(*) FROM applications WHERE app_key = 'app:invalid'") == 0)
        try db.close(); try await store.close()
    }

    @Test func migrationFromSixNeverBackfillsAndFailureRollsBack() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        let initial = try f.open()
        try await record(initial, f, upload: 7, measured: false)
        try await initial.close()
        let db = try SQLiteConnection(path: f.path)
        try db.execute("DROP TABLE application_usage_minutes")
        try db.execute("CREATE TABLE application_usage_minutes (evidence TEXT)")
        try db.execute("INSERT INTO application_usage_minutes VALUES ('retain')")
        try db.execute("PRAGMA user_version = 6")
        #expect(throws: StoreError.self) { try f.open() }
        #expect(try db.scalar("PRAGMA user_version") == 6)
        #expect(try db.query("SELECT evidence FROM application_usage_minutes", row: { $0.text(0) }) == ["retain"])
        try db.execute("DROP TABLE application_usage_minutes")
        let upgraded = try f.open()
        #expect(try db.scalar("PRAGMA user_version") == 7)
        #expect(try await upgraded.applicationTimeline(query(f)).buckets.isEmpty)
        #expect(try await upgraded.snapshot(day: f.day).first?.usage.uploadedBytes == 7)
        #expect(try db.query("PRAGMA integrity_check", row: { $0.text(0) }) == ["ok"])
        #expect(try db.query("PRAGMA foreign_key_check", row: { $0.text(0) }).isEmpty)
        try db.close(); try await upgraded.close()
    }

    @Test func retentionRemovesYesterdayAndQueryRejectsOtherDays() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        let store = try f.open()
        try await record(store, f, upload: 2)
        let yesterday = query(f)
        f.clock.advance(86_400)
        try await record(store, f, upload: 5)
        try await store.prunePreviousDays()
        let db = try SQLiteConnection(path: f.path)
        #expect(try db.scalar("SELECT COUNT(*) FROM application_usage_minutes") == 1)
        #expect(try await store.applicationTimeline(query(f)).buckets.first?.uploadedBytes == 5)
        do { _ = try await store.applicationTimeline(yesterday); Issue.record("Expected old-day rejection") } catch {}
        let invalid = ApplicationTimelineQuery(day: f.day, category: .metered,
            start: f.clock.now().addingTimeInterval(1), end: f.clock.now().addingTimeInterval(100))
        do { _ = try await store.applicationTimeline(invalid); Issue.record("Expected unaligned rejection") } catch {}
        try db.close(); try await store.close()
    }

    @Test func representativeIndexedReadHasBoundedReplyAndNoFullTableScan() async throws {
        let f = try StoreFixture(); defer { f.cleanup() }
        let store = try f.open()
        let db = try SQLiteConnection(path: f.path)
        let minute = Int64(f.clock.now().timeIntervalSince1970 * 1_000)
        try db.transaction {
            for app in 0..<128 {
                let key = "app:\(app)"
                try db.execute("INSERT INTO applications VALUES (?, ?)", [.text(key), .text(key)])
                for index in 0..<60 {
                    try db.execute("INSERT INTO application_usage_minutes VALUES (?, 'metered', ?, ?, 1, 2, 1)",
                        [.text(f.day), .integer(minute + Int64(index) * 60_000), .text(key)])
                }
            }
        }
        let plan = try db.query("""
            EXPLAIN QUERY PLAN SELECT app_key, uploaded_bytes FROM application_usage_minutes
            WHERE day = ? AND category = ? AND minute_start_ms >= ? AND minute_start_ms < ?
            """, [.text(f.day), .text("metered"), .integer(minute), .integer(minute + 3_600_000)]) { $0.text(3) }
        #expect(plan.contains { $0.contains("SEARCH") && $0.contains("INDEX") })
        #expect(!plan.contains { $0.contains("SCAN") })
        let start = ContinuousClock.now
        let result = try await store.applicationTimeline(query(f))
        let duration = start.duration(to: .now)
        #expect(result.buckets.count == 132)
        #expect(result.buckets.reduce(0) { $0 + $1.uploadedBytes } == 7_680)
        let encoded = try JSONEncoder().encode(AgentReply.applicationTimeline(result))
        #expect(encoded.count <= AgentEndpoint.maximumMessageBytes)
        print("Application minute fixture: 128 apps × 60 min; query \(duration), reply \(encoded.count) bytes; plan \(plan)")
        try db.close(); try await store.close()
    }
}
