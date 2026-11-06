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
    let result = try ApplicationTimelineGrouping.make(query: query, rows: rows, clashNotice: "Session coverage")
    let data = try #require(ApplicationTimelinePresentation.make(result))
    let names: Set<String> = ["App", "YouTube（Clash）"]
    #expect(Set(data.sources.map(\.name)) == names)
    #expect(Set(data.segments.map { $0.source.name }) == names)
    #expect(data.summary.totalBytes == 100)
    let tooltip = try #require(data.selection(at: start.addingTimeInterval(1), bytes: 1))
    #expect(Set(tooltip.applications.map(\.name)) == names)
    for direction in UsageDirection.allCases {
        let pie = data.pie(direction)
        #expect(Set(pie.slices.map(\.label)) == names)
        #expect(pie.totalBytes == (direction == .upload ? 40 : 60))
    }
    #expect(data.clashNotice == "Session coverage")
}
