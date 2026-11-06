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

    @Test func onlyContinuousFrameDeltasAreOfferedForPersistence() throws {
        var accumulator = MihomoProxyAccumulator()
        _ = try sample(&accumulator, bytes: 100, second: 58)
        #expect(accumulator.sourceIncrements.isEmpty)
        _ = try sample(&accumulator, bytes: 110, second: 60)
        #expect(accumulator.sourceIncrements.first?.uploadedBytes == 10)
        #expect(accumulator.sourceIncrements.first?.name == "YouTube（Clash）")
        #expect(accumulator.sourceIntervalStart == 59_000_000_000)
        accumulator.resetBaseline()
        #expect(accumulator.sourceIncrements.isEmpty)
        _ = try sample(&accumulator, bytes: 1_000, second: 62)
        #expect(accumulator.sourceIncrements.isEmpty)
        _ = try sample(&accumulator, bytes: 1_010, second: 64)
        #expect(accumulator.sourceIncrements.first?.downloadedBytes == 20)
        _ = try sample(&accumulator, bytes: 9_000, second: 120)
        #expect(accumulator.sourceIncrements.isEmpty)
        _ = try sample(&accumulator, bytes: 9_000, second: 122)
        #expect(accumulator.sourceIncrements.first?.uploadedBytes == 0)
        _ = try sample(&accumulator, bytes: 10_000, second: 124, category: nil)
        #expect(accumulator.sourceIncrements.isEmpty)
    }

    @Test func categoriesDayRollbackAndRestartRebuildDeltaBaseline() throws {
        var accumulator = MihomoProxyAccumulator()
        _ = try sample(&accumulator, bytes: 100, second: 0)
        _ = try sample(&accumulator, bytes: 110, second: 2)
        #expect(accumulator.sourceIncrements.first?.uploadedBytes == 10)
        _ = try sample(&accumulator, bytes: 1_000, second: 4, category: .ordinary)
        #expect(accumulator.sourceIncrements.isEmpty)
        _ = try sample(&accumulator, bytes: 1_030, second: 6, category: .ordinary)
        #expect(accumulator.sourceIncrements.first?.uploadedBytes == 30)
        _ = try sample(&accumulator, bytes: 2_000, second: 86_400)
        #expect(accumulator.sourceIncrements.isEmpty)
        _ = try sample(&accumulator, bytes: 2_100, second: 0)
        #expect(accumulator.sourceIncrements.isEmpty)
        _ = try sample(&accumulator, bytes: 2_110, second: 2)
        accumulator.reset()
        #expect(accumulator.sourceIncrements.isEmpty)
        #expect(MihomoProxyAccumulator().sourceIncrements.isEmpty)
    }
}
