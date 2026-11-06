import Foundation
import Testing
import FlowQuotaCore
@testable import FlowQuotaPlatform

struct MihomoTimelineTests {
    private let origin = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3_600)
    private var day: String { get throws { try LocalDay.key(for: origin, in: .current) } }
    private func query(_ category: TrafficCategory = .metered) throws -> ApplicationTimelineQuery {
        ApplicationTimelineQuery(day: try day, category: category, start: origin, end: origin.addingTimeInterval(600))
    }
    private func response(_ bytes: Int64) throws -> MihomoAPIResponse {
        let json: [String: Any] = ["uploadTotal": bytes, "downloadTotal": bytes * 2, "connections": [
            ["id": "connection-a", "upload": bytes, "download": bytes * 2,
             "metadata": ["host": "youtube.com"], "chains": ["DIRECT"]]]]
        return try MihomoAPIResponse.decode(JSONSerialization.data(withJSONObject: json))
    }
    private func sample(_ accumulator: inout MihomoProxyAccumulator, bytes: Int64, second: Int,
                        category: TrafficCategory? = .metered) throws -> MihomoProxySnapshot {
        try accumulator.consume(response(bytes), scope: "path", capturedAt: origin.addingTimeInterval(Double(second)),
            category: category, uptime: UInt64(second + 1) * 1_000_000_000)
    }

    @Test func sessionMinutesMatchListAndOnlyContinuousIntervalsAppear() throws {
        var accumulator = MihomoProxyAccumulator()
        _ = try sample(&accumulator, bytes: 100, second: 58)
        #expect(try accumulator.timelineRows(query()).isEmpty)
        _ = try sample(&accumulator, bytes: 110, second: 60)
        accumulator.resetBaseline()
        _ = try sample(&accumulator, bytes: 1_000, second: 62)
        let snapshot = try sample(&accumulator, bytes: 1_010, second: 64)
        let rows = try accumulator.timelineRows(query())
        #expect(rows.count == 1)
        #expect(rows.first?.name == snapshot.sources.first?.displayName)
        #expect(rows.first?.name == "YouTube（Clash）")
        #expect(rows.first?.uploadedBytes == 20)
        #expect(rows.first?.downloadedBytes == snapshot.sources.first?.downloadedBytes)
        #expect(rows.first?.sampleCount == 2)
        #expect(rows.first?.appKey == nil)
        #expect(rows.first?.clashSourceID == snapshot.sources.first?.id)
        // A gap and unknown network never allocate the missing interval.
        _ = try sample(&accumulator, bytes: 9_000, second: 120)
        _ = try sample(&accumulator, bytes: 9_000, second: 122)
        _ = try sample(&accumulator, bytes: 10_000, second: 124, category: nil)
        let after = try accumulator.timelineRows(query())
        #expect(after.reduce(0) { $0 + $1.uploadedBytes } == 20)
        #expect(after.reduce(0) { $0 + $1.sampleCount } == 3) // Observed zero is retained.
    }

    @Test func categoriesDayRollbackAndRestartCannotLeakMinutes() throws {
        var accumulator = MihomoProxyAccumulator()
        _ = try sample(&accumulator, bytes: 100, second: 0)
        _ = try sample(&accumulator, bytes: 110, second: 2)
        _ = try sample(&accumulator, bytes: 1_000, second: 4, category: .ordinary)
        _ = try sample(&accumulator, bytes: 1_030, second: 6, category: .ordinary)
        #expect(try accumulator.timelineRows(query()).first?.uploadedBytes == 10)
        #expect(try accumulator.timelineRows(query(.ordinary)).first?.uploadedBytes == 30)
        _ = try sample(&accumulator, bytes: 2_000, second: 86_400)
        #expect(try accumulator.timelineRows(query()).isEmpty)
        _ = try sample(&accumulator, bytes: 2_100, second: 0)
        #expect(try accumulator.timelineRows(query()).isEmpty)
        _ = try sample(&accumulator, bytes: 2_110, second: 2)
        accumulator.reset()
        #expect(try accumulator.timelineRows(query()).isEmpty)
        #expect(try MihomoProxyAccumulator().timelineRows(query()).isEmpty)
    }

    @Test func capacityRetainsEarnedRowsAndWarnsWithoutInventedAttribution() throws {
        var history = MihomoMinuteHistory(maximumRows: 1)
        history.setDay(try day)
        let source = MihomoProxySource(id: "site:youtube", displayName: "YouTube（Clash）", connectionCount: 1,
            uploadedBytes: 0, downloadedBytes: 0)
        try history.record(source: source, category: .metered, at: origin, upload: 1, download: 2)
        try history.record(source: source, category: .metered, at: origin.addingTimeInterval(60), upload: 10, download: 20)
        #expect(history.notice(for: .metered).contains("容量上限"))
        #expect(!history.notice(for: .ordinary).contains("容量上限"))
        #expect(try history.rows(for: query()).first?.uploadedBytes == 1)
        try history.record(source: source, category: .metered, at: origin.addingTimeInterval(2), upload: 3, download: 4)
        #expect(try history.rows(for: query()).first?.uploadedBytes == 4)
        history.setDay("2001-01-01")
        #expect(try history.rows(for: query()).isEmpty)
        #expect(!history.notice(for: .metered).contains("容量上限"))
    }
}
