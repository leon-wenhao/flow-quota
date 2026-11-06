import AppKit
import FlowQuotaCore
import SwiftUI
import Testing
@testable import FlowQuotaApp

@Test func hoverCoordinatesExcludeAxesAndAccountForPlotInsets() throws {
    let plot = CGRect(x: 60, y: 10, width: 400, height: 120)
    #expect(ChartTooltipLayout.plotLocation(CGPoint(x: 50, y: 40), in: plot) == nil)
    #expect(ChartTooltipLayout.plotLocation(CGPoint(x: 90, y: 140), in: plot) == nil)
    #expect(ChartTooltipLayout.plotLocation(CGPoint(x: 470, y: 40), in: plot) == nil)
    #expect(ChartTooltipLayout.plotLocation(CGPoint(x: 90, y: 5), in: plot) == nil)
    #expect(ChartTooltipLayout.plotLocation(CGPoint(x: 160, y: 50), in: plot) == CGPoint(x: 100, y: 40))
    #expect(ChartTooltipLayout.plotLocation(.zero, in: .zero) == nil)
}

@Test(arguments: [CGPoint(x: 5, y: 5), CGPoint(x: 510, y: 5),
                  CGPoint(x: 5, y: 160), CGPoint(x: 510, y: 160), CGPoint(x: 260, y: 80)])
func tooltipStaysInsideChartIncludingLastBucket(pointer: CGPoint) {
    let bounds = CGRect(x: 0, y: 0, width: 520, height: 166)
    let size = CGSize(width: 224, height: 126)
    let origin = ChartTooltipLayout.origin(at: pointer, size: size, bounds: bounds)
    let tooltip = CGRect(origin: origin, size: size)
    #expect(bounds.insetBy(dx: 4, dy: 4).contains(tooltip))
    if pointer.x == 510 { #expect(tooltip.maxX < pointer.x) }
}

@MainActor @Test(arguments: [false, true])
func tooltipContentsFitReservedOverlayWithoutChangingChartHeight(observed: Bool) throws {
    _ = NSApplication.shared
    let data = try #require(ApplicationTimelinePresentation.make(applicationTimelineFixture(observed: observed)))
    let selection = try #require(data.selection(at: data.summary.interval.start.addingTimeInterval(220), bytes: 0))
    let content = UsageTimelineTooltip(selection: selection, sourceIDs: data.sources.map(\.id))
    let tooltip = NSHostingView(rootView: content.frame(width: UsageTimelineTooltip.width)
        .fixedSize(horizontal: false, vertical: true))
    tooltip.layoutSubtreeIfNeeded()
    #expect(tooltip.fittingSize.height <= content.height)
    let chart = NSHostingView(rootView: UsageTimelineChart(data: data).frame(width: 520))
    chart.layoutSubtreeIfNeeded()
    #expect(chart.fittingSize == CGSize(width: 520, height: 190))
}

@MainActor @Test func tenAppsAndRemainingFitInsideFloatingTooltip() throws {
    _ = NSApplication.shared
    let base = applicationTimelineFixture()
    var rows: [ApplicationUsageBucket] = []
    for index in 0..<11 {
        let key: String? = index == 10 ? nil : "app:\(index)"
        let name = index == 10 ? "其他应用" : "名称很长的应用程序 \(index)"
        rows.append(ApplicationUsageBucket(appKey: key, name: name,
            startMilliseconds: 1_800_000_000_000, uploadedBytes: Int64(index),
            downloadedBytes: Int64(11 - index) * 1_000_000_000, sampleCount: 1))
    }
    let data = try #require(ApplicationTimelinePresentation.make(ApplicationUsageTimeline(
        query: base.query, bucketMinutes: 5, buckets: rows)))
    let selection = try #require(data.selection(at: base.query.start.addingTimeInterval(220), bytes: 1))
    #expect(selection.applications.count == 11)
    let content = UsageTimelineTooltip(selection: selection, sourceIDs: data.sources.map(\.id))
    let host = NSHostingView(rootView: content.frame(width: UsageTimelineTooltip.width)
        .fixedSize(horizontal: false, vertical: true))
    host.layoutSubtreeIfNeeded()
    #expect(host.fittingSize.height <= content.height)
    #expect(content.height <= 288)
    let bounds = CGRect(x: 0, y: 0, width: 520, height: 300)
    let size = CGSize(width: UsageTimelineTooltip.width, height: content.height)
    for pointer in [CGPoint(x: 5, y: 5), CGPoint(x: 510, y: 295)] {
        let origin = ChartTooltipLayout.origin(at: pointer, size: size, bounds: bounds)
        #expect(bounds.insetBy(dx: 4, dy: 4).contains(CGRect(origin: origin, size: size)))
    }
}

@MainActor @Test func longTooltipUsesVisibleViewportWhenChartIsPartlyScrolled() {
    let viewport = CGRect(x: 180, y: 80, width: 570, height: 400)
    let size = CGSize(width: UsageTimelineTooltip.width, height: 282)
    for chartY in [CGFloat(230), CGFloat(20), CGFloat(400)] {
        let chart = CGRect(x: 220, y: chartY, width: 500, height: 190)
        let bounds = ChartTooltipLayout.visibleBounds(chartFrame: chart, viewport: viewport)
        let point = CGPoint(x: 480, y: min(170, max(5, viewport.midY - chartY)))
        let origin = ChartTooltipLayout.origin(at: point, size: size, bounds: bounds)
        let global = CGRect(origin: origin, size: size).offsetBy(dx: chart.minX, dy: chart.minY)
        #expect(viewport.insetBy(dx: 4, dy: 4).contains(global))
    }
}
