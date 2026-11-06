import AppKit
import Foundation
import FlowQuotaCore
import SwiftUI
import Testing
@testable import FlowQuotaApp

func applicationTimelineFixture(observed: Bool = true) -> ApplicationUsageTimeline {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let query = ApplicationTimelineQuery(day: "2027-01-15", category: .ordinary,
        start: start, end: start.addingTimeInterval(600))
    return ApplicationUsageTimeline(query: query, bucketMinutes: 5, buckets: observed ? [
        ApplicationUsageBucket(appKey: "a", name: "同名应用", startMilliseconds: 1_800_000_000_000,
            uploadedBytes: 10, downloadedBytes: 30, sampleCount: 1),
        ApplicationUsageBucket(appKey: "b", name: "同名应用", startMilliseconds: 1_800_000_000_000,
            uploadedBytes: 20, downloadedBytes: 40, sampleCount: 1)
    ] : [])
}

@Test func stacksPiesAndHoverUseTheSameRangeAndApplicationIdentity() throws {
    let data = try #require(ApplicationTimelinePresentation.make(applicationTimelineFixture()))
    #expect(data.summary.totalBytes == 100)
    #expect(data.summary.slots[0].sampleCount == 2)
    #expect(data.summary.slots[1].sampleCount == 0)
    #expect(data.sources.map(\.id) == ["app:b", "app:a"])
    #expect(data.segments.count == 4)
    #expect(data.segments.map(\.lower) == [0, 20, 0, 40])
    #expect(data.segments.map(\.upper) == [20, 30, 40, 70])
    #expect(data.pie(.upload).totalBytes == 30)
    #expect(data.pie(.download).totalBytes == 70)
    #expect(data.pie(.upload).slices.map(\.id) == data.sources.map(\.id))
    let start = data.summary.interval.start
    #expect(data.selection(at: start.addingTimeInterval(70), bytes: 25)?.source?.id == "app:a")
    #expect(data.selection(at: start.addingTimeInterval(70), bytes: 25)?.bytes == 10)
    #expect(data.selection(at: start.addingTimeInterval(220), bytes: 10)?.source?.id == "app:b")
    #expect(data.selection(at: start.addingTimeInterval(220), bytes: 10)?.bytes == 40)
    #expect(data.selection(at: start.addingTimeInterval(320), bytes: 0)?.bytes == nil)
    #expect(data.selection(at: data.summary.interval.end, bytes: 0) == nil)
}

@Test func malformedAndOverflowedResultsCannotBecomeValidCharts() throws {
    let valid = applicationTimelineFixture()
    for rows in [valid.buckets + valid.buckets, [ApplicationUsageBucket(appKey: "a", name: "a",
        startMilliseconds: 1_800_000_000_001, uploadedBytes: 1, downloadedBytes: 1, sampleCount: 1)],
        [ApplicationUsageBucket(appKey: "a", name: "a", startMilliseconds: 1_800_000_000_000,
            uploadedBytes: Int64.max, downloadedBytes: 1, sampleCount: 1)]] {
        #expect(ApplicationTimelinePresentation.make(ApplicationUsageTimeline(query: valid.query,
            bucketMinutes: 5, buckets: rows)) == nil)
    }
    let empty = try #require(ApplicationTimelinePresentation.make(applicationTimelineFixture(observed: false)))
    #expect(empty.summary.totalBytes == nil)
    let zero = ApplicationUsageTimeline(query: valid.query, bucketMinutes: 5, buckets: [
        ApplicationUsageBucket(appKey: "a", name: "a", startMilliseconds: 1_800_000_000_000,
            uploadedBytes: 0, downloadedBytes: 0, sampleCount: 1)])
    #expect(ApplicationTimelinePresentation.make(zero)?.summary.totalBytes == 0)
}

@Test func pieHoverRejectsDonutHoleAndMapsSectorBoundaries() {
    let plot = CGRect(x: 50, y: 20, width: 200, height: 180)
    #expect(!PieHoverSelection.isInRing(CGPoint(x: 150, y: 110), plot: plot))
    #expect(PieHoverSelection.isInRing(CGPoint(x: 150, y: 30), plot: plot))
    #expect(!PieHoverSelection.isInRing(CGPoint(x: 30, y: 30), plot: plot))
    let data = UsagePieData(slices: [UsagePieSlice(id: "a", label: "A", bytes: 30),
        UsagePieSlice(id: "b", label: "B", bytes: 70)], totalBytes: 100)
    #expect(PieHoverSelection.slice(at: 0, data: data)?.id == "a")
    #expect(PieHoverSelection.slice(at: 29.9, data: data)?.id == "a")
    #expect(PieHoverSelection.slice(at: 30, data: data)?.id == "b")
    #expect(PieHoverSelection.slice(at: 99.9, data: data)?.id == "b")
    #expect(PieHoverSelection.slice(at: 100, data: data) == nil)
    #expect(PieHoverSelection.slice(at: .nan, data: data) == nil)
}

@MainActor @Test func pairedPiesFitSideBySideWithoutTextLists() throws {
    _ = NSApplication.shared
    let data = try #require(ApplicationTimelinePresentation.make(applicationTimelineFixture()))
    let host = NSHostingView(rootView: HStack(alignment: .top, spacing: 20) {
        UsagePieChart(data: data.pie(.upload), title: "上传", sourceIDs: data.sources.map(\.id))
        UsagePieChart(data: data.pie(.download), title: "下载", sourceIDs: data.sources.map(\.id))
    }.frame(width: 520))
    host.layoutSubtreeIfNeeded()
    #expect(host.fittingSize.width == 520)
    #expect(host.fittingSize.height < 300)
}

@MainActor @Test func sourceRankingAndPairedPiesKeepAllSourcesWithinBoundedHeight() throws {
    _ = NSApplication.shared
    let base = applicationTimelineFixture()
    let rows = (0..<24).map { index in
        ApplicationUsageBucket(appKey: "app-\(index)", name: "来源 \(index)",
            startMilliseconds: 1_800_000_000_000, uploadedBytes: Int64(index + 1),
            downloadedBytes: Int64(index + 2), sampleCount: 1)
    }
    let data = try #require(ApplicationTimelinePresentation.make(ApplicationUsageTimeline(
        query: base.query, bucketMinutes: 5, buckets: rows)))
    #expect(data.sources.count == 24)
    #expect(data.pie(.upload).slices.count == 24)
    #expect(data.pie(.download).slices.count == 24)
    let host = NSHostingView(rootView: UsageChartsView(data: data).frame(width: 520))
    host.layoutSubtreeIfNeeded()
    #expect(host.fittingSize.width == 520)
    #expect(host.fittingSize.height < 620)
}

@MainActor @Test func nativeApplicationChartFixtureCanBeRenderedWithoutSampling() async throws {
    _ = NSApplication.shared
    let base = applicationTimelineFixture()
    let fixture = ApplicationUsageTimeline(query: base.query, bucketMinutes: 5, buckets: [
        ApplicationUsageBucket(appKey: "chrome", name: "Chrome", startMilliseconds: 1_800_000_000_000,
            uploadedBytes: 8_000_000, downloadedBytes: 27_000_000, sampleCount: 20),
        ApplicationUsageBucket(appKey: "feishu", name: "飞书", startMilliseconds: 1_800_000_000_000,
            uploadedBytes: 12_000_000, downloadedBytes: 5_000_000, sampleCount: 20),
        ApplicationUsageBucket(appKey: "chrome", name: "Chrome", startMilliseconds: 1_800_000_300_000,
            uploadedBytes: 3_000_000, downloadedBytes: 17_000_000, sampleCount: 10),
        ApplicationUsageBucket(appKey: "feishu", name: "飞书", startMilliseconds: 1_800_000_300_000,
            uploadedBytes: 5_000_000, downloadedBytes: 11_000_000, sampleCount: 10)
    ])
    let data = try #require(ApplicationTimelinePresentation.make(fixture))
    let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 16) {
        Text("应用分时用量 · 模拟数据").font(.title2.bold())
        SettingsSection(title: "左上传 · 右下载") { UsageTimelineChart(data: data) }
        UsageChartsView(data: data)
    }.padding(20).frame(width: 620).background(Color(nsColor: .windowBackgroundColor)))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 700),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    host.frame.size = host.fittingSize
    try await Task.sleep(for: .milliseconds(50))
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/flow-quota-application-chart-fixture.png"))
    #expect(host.fittingSize.height < 720)
}

@Test func intervalTooltipListsEveryDisplayedSourceAndPreservesAbsoluteBytesAndZeros() throws {
    let base = applicationTimelineFixture()
    let rows = [
        ApplicationUsageBucket(appKey: "a", name: "A", startMilliseconds: 1_800_000_000_000,
            uploadedBytes: 100, downloadedBytes: 0, sampleCount: 1),
        ApplicationUsageBucket(appKey: "b", name: "B", startMilliseconds: 1_800_000_000_000,
            uploadedBytes: 200, downloadedBytes: 600, sampleCount: 1),
        ApplicationUsageBucket(appKey: nil, name: "其他应用", startMilliseconds: 1_800_000_000_000,
            uploadedBytes: 500, downloadedBytes: 100, sampleCount: 1),
        ApplicationUsageBucket(appKey: "c", name: "C", startMilliseconds: 1_800_000_300_000,
            uploadedBytes: 10, downloadedBytes: 20, sampleCount: 1)
    ]
    let data = try #require(ApplicationTimelinePresentation.make(ApplicationUsageTimeline(
        query: base.query, bucketMinutes: 5, buckets: rows)))
    let upload = try #require(data.selection(at: base.query.start.addingTimeInterval(70), bytes: 250))
    #expect(upload.totalBytes == 800)
    #expect(upload.applications.map(\.name) == ["B", "A", "其他应用"])
    #expect(upload.applications.reduce(0) { $0 + $1.uploadedBytes } == 800)
    #expect(data.segments.filter { $0.slotIndex == 0 && $0.direction == .upload }.last?.upper == 800)
    #expect(data.segments.filter { $0.slotIndex == 0 && $0.direction == .download }.last?.upper == 700)
    let download = try #require(data.selection(at: base.query.start.addingTimeInterval(220), bytes: 550))
    #expect(download.totalBytes == 700)
    #expect(download.source?.name == "B")
    #expect(download.applications.map(\.name) == ["B", "A", "其他应用"])
    #expect(download.applications.first { $0.name == "A" }?.downloadedBytes == 0)
    #expect(download.applications.first { $0.name == "C" } == nil)
    let second = try #require(data.selection(at: base.query.start.addingTimeInterval(350), bytes: 1))
    #expect(second.applications.map(\.name) == ["C"])
}
