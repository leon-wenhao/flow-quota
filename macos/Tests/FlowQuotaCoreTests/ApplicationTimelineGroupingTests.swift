import Foundation
import Testing
@testable import FlowQuotaCore

struct ApplicationTimelineGroupingTests {
    private let start = Date(timeIntervalSince1970: 1_794_000_000)
    private var query: ApplicationTimelineQuery {
        ApplicationTimelineQuery(day: "2026-11-06", category: .metered, start: start, end: start.addingTimeInterval(600))
    }
    private func row(_ key: String?, name: String, bytes: Int64, clash: String? = nil, minute: Int64 = 0) -> ApplicationUsageBucket {
        ApplicationUsageBucket(appKey: key, name: name, startMilliseconds: Int64(start.timeIntervalSince1970 * 1_000) + minute * 60_000,
            uploadedBytes: 0, downloadedBytes: bytes, sampleCount: 1, clashSourceID: clash)
    }

    @Test func proxyAndEveryLowRankedSourceRemainAvailable() throws {
        let kernel = row("exec:/Library/Application Support/clash-verge-service/cores/verge-mihomo", name: "verge-mihomo", bytes: 1_000_000)
        var rows = (0..<11).map { row("exec:/test/\($0)", name: "App \($0)", bytes: Int64($0 + 1)) }
        rows += [kernel, row(nil, name: "YouTube（Clash）", bytes: 100, clash: "site:youtube")]
        let result = try ApplicationTimelineGrouping.make(query: query, rows: rows)
        #expect(result.buckets.count == 13)
        #expect(result.buckets.contains { $0.clashSourceID == "site:youtube" && $0.name == "YouTube（Clash）" })
        #expect(result.buckets.contains { $0.appKey == kernel.appKey })
        #expect(result.buckets.reduce(0) { $0 + $1.downloadedBytes } == 1_000_166)
        #expect(!result.buckets.contains { $0.sourceID == "remaining" })
    }

    @Test func namesNamespacesAndBucketDenominatorsStayConsistent() throws {
        let rows = [row("exec:/usr/libexec/nsurlsessiond", name: "nsurlsessiond", bytes: 2),
                    row("exec:/test/Browser", name: "Browser", bytes: 4),
                    row(nil, name: "Browser（Clash）", bytes: 6, clash: "exec:/test/Browser"),
                    row(nil, name: "Browser（Clash）", bytes: 0, clash: "exec:/test/Browser", minute: 5)]
        let result = try ApplicationTimelineGrouping.make(query: query, rows: rows, clashNotice: "session only")
        #expect(result.buckets.first { $0.appKey == "exec:/usr/libexec/nsurlsessiond" }?.name == "系统共享下载服务（nsurlsessiond）")
        #expect(Set(result.buckets.map(\.sourceID)).count == 3)
        #expect(result.buckets.filter { $0.clashSourceID != nil }.count == 2)
        #expect(result.clashNotice == "session only")
        let roundTrip = try JSONDecoder().decode(ApplicationUsageTimeline.self, from: JSONEncoder().encode(result))
        #expect(roundTrip == result)
        let previous = "{\"appKey\":\"exec:/test/A\",\"name\":\"A\",\"startMilliseconds\":0,\"uploadedBytes\":0,\"downloadedBytes\":0,\"sampleCount\":1}"
        #expect(try JSONDecoder().decode(ApplicationUsageBucket.self, from: Data(previous.utf8)).clashSourceID == nil)
    }

    @Test func checkedRowsRejectOverflowInsteadOfWrapping() {
        #expect(throws: (any Error).self) {
            try ApplicationTimelineGrouping.make(query: query, rows: [
                ApplicationUsageBucket(appKey: "exec:/test/App", name: "App",
                    startMilliseconds: 0, uploadedBytes: Int64.max, downloadedBytes: 1, sampleCount: 1)])
        }
    }
}
