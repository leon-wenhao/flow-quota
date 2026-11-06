import AppKit
import SwiftUI
import Foundation
import FlowQuotaCore
import Testing
@testable import FlowQuotaApp

struct MacTrafficTimelineTests {
    let start = Date(timeIntervalSince1970: 1_794_000_000)
    var query: ApplicationTimelineQuery {
        ApplicationTimelineQuery(day: "2026-11-06", category: .metered, start: start, end: start.addingTimeInterval(600))
    }
    var timestamp: Int64 { Int64(start.timeIntervalSince1970 * 1_000) }

    @Test func fullInterfaceBurstSurvivesPartialClashRecognitionAndProxyFallback() throws {
        let minutes = [InterfaceUsageMinute(minuteStartMilliseconds: timestamp + 60_000,
            uploadedBytes: 41_725_952, downloadedBytes: 790_343_680, sampleCount: 29)]
        let meter = try #require(MacTrafficTimeline.make(query: query, minutes: minutes))
        let rows = [ApplicationUsageBucket(appKey: "exec:/Library/Application Support/clash-verge-service/cores/verge-mihomo",
            name: "verge-mihomo", startMilliseconds: timestamp, uploadedBytes: 30_063_756,
            downloadedBytes: 775_751_613, sampleCount: 29),
            ApplicationUsageBucket(appKey: nil, name: "Logi Options+（Clash）", startMilliseconds: timestamp,
                uploadedBytes: 1_000, downloadedBytes: 322_900_000, sampleCount: 29, clashSourceID: "logi")]
        let resolved = try ClashMinuteBreakdown.resolve(processes: [rows[0]], sources: [ClashMinuteUsage(minute: timestamp,
            source: ClashUsageSource(id: "logi", name: rows[1].name, uploadedBytes: 1_000, downloadedBytes: 322_900_000))])
        let result = ApplicationUsageTimeline(query: query, bucketMinutes: 5, buckets: resolved.rows, sourcesResolved: true)
        let processes = try #require(ApplicationTimelinePresentation.make(result))
        #expect(meter.summary.downloadedBytes == 790_343_680)
        #expect(meter.summary.totalBytes == 832_069_632)
        #expect(meter.segments.filter { $0.direction == .download }.reduce(0) { $0 + $1.bytes } == 790_343_680)
        #expect(processes.summary.totalBytes == 805_815_369)
        #expect(processes.sources.first?.name == "其他未识别（Clash）")
        #expect(processes.sources.first { $0.name == "Logi Options+（Clash）" }?.downloadedBytes == 322_900_000)
        #expect(processes.sources.count == 2)
        // No subtraction from the meter and no kernel + API double counting.
        #expect(TrafficMeasurementComparison(total: meter.summary.totalBytes, sources: processes.summary.totalBytes)
                == .unexplained(26_254_263))
    }

    @Test func zeroUnknownRangeBoundsAndNoApplicationRecordStayDistinct() throws {
        let zero = InterfaceUsageMinute(minuteStartMilliseconds: timestamp, uploadedBytes: 0, downloadedBytes: 0, sampleCount: 1)
        let outside = InterfaceUsageMinute(minuteStartMilliseconds: timestamp + 600_000,
            uploadedBytes: 800_000_000, downloadedBytes: 800_000_000, sampleCount: 1)
        let data = try #require(MacTrafficTimeline.make(query: query, minutes: [zero, outside]))
        #expect(data.summary.totalBytes == 0)
        #expect(data.summary.slots[0].sampleCount == 1)
        #expect(data.summary.slots[1].sampleCount == 0)
        #expect(data.selection(at: start.addingTimeInterval(301), bytes: 0)?.totalBytes == nil)
        #expect(MacTrafficTimeline.make(query: query, minutes: [])?.summary.totalBytes == nil)
        #expect(MacTrafficTimeline.make(query: query, minutes: nil) == nil)
    }

    @Test func duplicateNegativeAndOverflowedMeterRowsRemainUnknown() {
        let valid = InterfaceUsageMinute(minuteStartMilliseconds: timestamp, uploadedBytes: 0, downloadedBytes: 1, sampleCount: 1)
        #expect(MacTrafficTimeline.make(query: query, minutes: [valid, valid]) == nil)
        for bytes in [Int64(-1), .max] {
            let invalid = InterfaceUsageMinute(minuteStartMilliseconds: timestamp,
                uploadedBytes: 1, downloadedBytes: bytes, sampleCount: 1)
            #expect(MacTrafficTimeline.make(query: query, minutes: [invalid]) == nil)
        }
    }

    @Test func sourceFailureDoesNotRemoveIndependentMeterAndDirectionsCannotCancelGaps() throws {
        let minutes = [InterfaceUsageMinute(minuteStartMilliseconds: timestamp,
            uploadedBytes: 100, downloadedBytes: 700, sampleCount: 1)]
        let meter = try #require(MacTrafficTimeline.make(query: query, minutes: minutes))
        let invalid = ApplicationUsageTimeline(query: query, bucketMinutes: query.bucketMinutes,
            buckets: [ApplicationUsageBucket(appKey: "exec:/broken", name: "Broken",
                startMilliseconds: timestamp, uploadedBytes: -1, downloadedBytes: 1, sampleCount: 1)])
        #expect(ApplicationTimelinePresentation.make(invalid) == nil)
        #expect(meter.summary.totalBytes == 800)
        // Equal combined sums can still hide opposite discrepancies in each direction.
        #expect(TrafficMeasurementComparison(total: 800, sources: 800) == .equal)
        #expect(TrafficMeasurementComparison(total: meter.summary.uploadedBytes, sources: 200) == .overlapping(100))
        #expect(TrafficMeasurementComparison(total: meter.summary.downloadedBytes, sources: 600) == .unexplained(100))
    }

    @Test func moreThanTenSourcesArePreservedAndClashIsNeverAddedToProcessTotals() throws {
        var rows = (0..<32).map { index in
            ApplicationUsageBucket(appKey: "exec:/test/\(index)", name: "App \(index)",
                startMilliseconds: timestamp, uploadedBytes: 0, downloadedBytes: 1, sampleCount: 1)
        }
        rows.append(ApplicationUsageBucket(appKey: nil, name: "App（Clash）", startMilliseconds: timestamp,
            uploadedBytes: 0, downloadedBytes: 10, sampleCount: 1, clashSourceID: "app"))
        let result = try ApplicationTimelineGrouping.make(query: query, rows: rows)
        let data = try #require(ApplicationTimelinePresentation.make(result))
        #expect(data.sources.count == 32)
        #expect(data.summary.totalBytes == 32)
        #expect(data.pie(.download).slices.count == 32)
        #expect(data.selection(at: start.addingTimeInterval(200), bytes: 1)?.applications.count == 32)
    }
}

/// Synthetic regression fixture only; never invokes nettop or reads the live store.
@MainActor @Test func nativeFullTotalPreviewAndTooltipStayReadable() throws {
    let fixture = MacTrafficTimelineTests()
    let minutes = [InterfaceUsageMinute(minuteStartMilliseconds: fixture.timestamp,
        uploadedBytes: 41_725_952, downloadedBytes: 790_343_680, sampleCount: 29)]
    let meter = try #require(MacTrafficTimeline.make(query: fixture.query, minutes: minutes))
    let rows = [ApplicationUsageBucket(appKey: "exec:/Library/Application Support/clash-verge-service/cores/verge-mihomo",
        name: "verge-mihomo", startMilliseconds: fixture.timestamp, uploadedBytes: 30_063_756,
        downloadedBytes: 775_751_613, sampleCount: 29)]
    let result = try ApplicationTimelineGrouping.make(query: fixture.query, rows: rows)
    let processes = try #require(ApplicationTimelinePresentation.make(result))
    let selection = try #require(meter.selection(at: fixture.start.addingTimeInterval(200), bytes: 100))
    let processSelection = try #require(processes.selection(at: fixture.start.addingTimeInterval(200), bytes: 100))
    let tooltip = UsageTimelineTooltip(selection: selection, sourceIDs: processes.sources.map(\.id),
        processSelection: processSelection, isInterface: true)
    let tooltipHost = NSHostingView(rootView: tooltip.frame(width: UsageTimelineTooltip.width))
    #expect(tooltipHost.fittingSize.height <= tooltip.height)
    _ = NSApplication.shared
    let content = VStack(alignment: .leading, spacing: 14) {
        Text("流量展示回归（模拟数据）").font(.title2.bold())
        HStack {
            Text("Mac 上传＋下载总量").font(.headline)
            Spacer()
            Text(UsageFormatter.bytes(meter.summary.totalBytes)).font(.title.bold())
        }
        Text("下载 790.3 MB · 上传 41.7 MB").font(.subheadline)
        UsageTimelineChart(data: meter, processes: processes, isInterface: true)
        UsageChartsView(data: processes)
    }
    .padding(20).frame(width: 700, height: 900)
    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
    let host = NSHostingView(rootView: content)
    host.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    let png = try #require(rep.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/flow-quota-full-traffic-fixture.png"))
    window.orderOut(nil)
}
