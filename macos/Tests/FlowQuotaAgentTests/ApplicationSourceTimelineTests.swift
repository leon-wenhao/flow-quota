import Foundation
import Testing
import FlowQuotaCore
import FlowQuotaPlatform
import FlowQuotaStore
@testable import FlowQuotaAgent

@Test func applicationTimelineUsesListSourcesWithoutChangingDurableLedgers() async throws {
    try await withRegressionRuntime { runtime, store, clock, _, _ in
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3_600)
        let day = try LocalDay.key(for: start, in: .current)
        let kernel = AppIdentity(key: "exec:/Library/Application Support/clash-verge-service/cores/verge-mihomo", name: "verge-mihomo")
        let browser = AppIdentity(key: "exec:/simulated/Browser", name: "Browser")
        try await store.recordSample(day: day, increments: [
            UsageIncrement(identity: kernel, uploadedBytes: 1_000, downloadedBytes: 2_000),
            UsageIncrement(identity: browser, uploadedBytes: 10, downloadedBytes: 20)],
            applicationObservedAt: start.addingTimeInterval(2), observedApplicationKeys: [kernel.key, browser.key])
        let before = try await store.snapshot(day: day)
        for (second, bytes) in [(0, Int64(100)), (2, Int64(150))] {
            let object: [String: Any] = ["uploadTotal": bytes, "downloadTotal": bytes * 2,
                "connections": [["id": "a", "upload": bytes, "download": bytes * 2,
                                  "metadata": ["host": "youtube.com"], "chains": ["DIRECT"]]]]
            let response = try MihomoAPIResponse.decode(JSONSerialization.data(withJSONObject: object))
            clock.setTime(UInt64(second + 1) * 1_000_000_000)
            await runtime.ingestMihomo(response, generation: 0, capturedAt: start.addingTimeInterval(Double(second)))
        }
        let query = ApplicationTimelineQuery(day: day, category: .metered, start: start, end: start.addingTimeInterval(300))
        guard case .applicationTimeline(let result) = try await runtime.handle(.applicationTimeline(query)) else {
            Issue.record("Expected source timeline"); return
        }
        #expect(result.buckets.count == 2)
        #expect(!result.buckets.contains { $0.appKey == kernel.key })
        let clash = try #require(result.buckets.first { $0.clashSourceID != nil })
        #expect(clash.name == "YouTube（Clash）")
        #expect(clash.uploadedBytes == 50 && clash.downloadedBytes == 100)
        #expect(clash.appKey == nil)
        #expect(result.buckets.reduce(0) { $0 + $1.uploadedBytes + $1.downloadedBytes } == 180)
        #expect(result.clashNotice?.contains("重启清空") == true)
        let after = try await store.snapshot(day: day)
        #expect(after.map(\.identity) == before.map(\.identity))
        #expect(after.map(\.usage) == before.map(\.usage))
        #expect(try await store.interfaceUsage(day: day) == nil)
        #expect(try await store.trafficAlertEvents(day: day).isEmpty)
        let encoded = try JSONEncoder().encode(AgentReply.applicationTimeline(result))
        #expect(encoded.count < AgentEndpoint.maximumMessageBytes)
    }
}
