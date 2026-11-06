import Foundation
import FlowQuotaCore
import Testing
@testable import FlowQuotaApp

@Test func listSourceNamesCarryThroughStacksTooltipAndBothPies() throws {
    let start = Date(timeIntervalSince1970: 1_794_000_000)
    let query = ApplicationTimelineQuery(day: "2026-11-06", category: .metered,
        start: start, end: start.addingTimeInterval(300))
    let minute = Int64(start.timeIntervalSince1970 * 1_000)
    let rows = [
        ApplicationUsageBucket(appKey: "exec:/Library/Application Support/clash-verge-service/cores/verge-mihomo",
            name: "verge-mihomo", startMilliseconds: minute, uploadedBytes: 900, downloadedBytes: 900, sampleCount: 1),
        ApplicationUsageBucket(appKey: "exec:/test/App", name: "App", startMilliseconds: minute,
            uploadedBytes: 10, downloadedBytes: 20, sampleCount: 1),
        ApplicationUsageBucket(appKey: nil, name: "YouTube（Clash）", startMilliseconds: minute,
            uploadedBytes: 30, downloadedBytes: 40, sampleCount: 1, clashSourceID: "site:youtube")]
    let resolved = try ClashMinuteBreakdown.resolve(processes: Array(rows.prefix(2)), sources: [ClashMinuteUsage(minute: minute,
        source: ClashUsageSource(id: "site:youtube", name: "YouTube（Clash）", uploadedBytes: 30, downloadedBytes: 40))])
    let result = ApplicationUsageTimeline(query: query, bucketMinutes: 5, buckets: resolved.rows, sourcesResolved: true)
    let data = try #require(ApplicationTimelinePresentation.make(result))
    let names: Set<String> = ["App", "YouTube（Clash）", "其他未识别（Clash）"]
    #expect(Set(data.sources.map(\.name)) == names)
    #expect(Set(data.segments.map { $0.source.name }) == names)
    #expect(data.summary.totalBytes == 1830)
    let tooltip = try #require(data.selection(at: start.addingTimeInterval(1), bytes: 1))
    #expect(Set(tooltip.applications.map(\.name)) == names)
    for direction in UsageDirection.allCases {
        let pie = data.pie(direction)
        #expect(Set(pie.slices.map(\.label)) == names)
        #expect(pie.totalBytes == (direction == .upload ? 910 : 920))
    }
    #expect(!data.sources.contains { $0.name.contains("内核") })
}
