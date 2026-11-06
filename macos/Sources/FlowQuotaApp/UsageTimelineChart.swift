import Charts
import SwiftUI

struct UsageTimelineChart: View {
    let data: ApplicationTimelinePresentation
    var processes: ApplicationTimelinePresentation?
    var clash: ApplicationTimelinePresentation?
    var isInterface = false
    @Environment(\.chartTooltipViewport) private var tooltipViewport
    @State private var hoverLocation: CGPoint?

    var body: some View {
        Chart {
            ForEach(data.segments) { segment in
                let slot = data.summary.slots[segment.slotIndex]
                RectangleMark(xStart: .value("开始", edge(slot, direction: segment.direction, trailing: false)),
                    xEnd: .value("结束", edge(slot, direction: segment.direction, trailing: true)),
                    yStart: .value("字节", Double(segment.lower)), yEnd: .value("字节", Double(segment.upper)))
                    .foregroundStyle(color(segment.source.id))
                    .accessibilityLabel("\(time(slot.start))–\(time(slot.end))，\(segment.source.name)\(segment.direction.rawValue)")
                    .accessibilityValue("\(UsageFormatter.bytes(segment.bytes))，\(isInterface ? "接口总量" : "进程观测，可能重叠")")
            }
            ForEach(data.summary.slots.filter { $0.sampleCount > 0 }) { slot in
                ForEach(UsageDirection.allCases) { direction in
                    if direction.bytes(upload: slot.uploadedBytes, download: slot.downloadedBytes) == 0 {
                        PointMark(x: .value("时间", center(slot, direction: direction)), y: .value("字节", 0))
                            .foregroundStyle(.secondary).symbolSize(12)
                    }
                }
            }
        }
        .chartXScale(domain: data.summary.interval.start...data.summary.interval.end)
        .chartYScale(domain: 0...max(1, data.summary.slots.map { Double(max($0.uploadedBytes, $0.downloadedBytes)) }.max() ?? 1))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel { if let bytes = value.as(Double.self) { Text(axisBytes(bytes)) } }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    hoverOverlay(proxy, plot: geometry[anchor], size: geometry.size,
                        bounds: ChartTooltipLayout.visibleBounds(chartFrame: geometry.frame(in: .global), viewport: tooltipViewport))
                }
            }
        }
        .frame(height: 190)
        .accessibilityLabel(isInterface ? "Mac 分时总流量，左柱上传、右柱下载；含全部接口观测，空白未知，圆点为零" : "进程分时观测，可能重叠；空白未观测，圆点为零")
        .onChange(of: data.summary.interval) { _, _ in hoverLocation = nil }
        .onChange(of: data.sources.map(\.id)) { _, _ in hoverLocation = nil }
        .onDisappear { hoverLocation = nil }
    }

    private func hoverOverlay(_ proxy: ChartProxy, plot: CGRect, size: CGSize, bounds: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverLocation = plot.contains(point) ? point : nil
                case .ended: hoverLocation = nil
                }
            }
            if let point = hoverLocation,
               let location = ChartTooltipLayout.plotLocation(point, in: plot),
               let date: Date = proxy.value(atX: location.x), let bytes: Double = proxy.value(atY: location.y),
               let selection = data.selection(at: date, bytes: bytes) {
                let tooltip = UsageTimelineTooltip(selection: selection,
                    sourceIDs: (processes ?? data).sources.map(\.id),
                    processSelection: processes?.selection(at: date, bytes: bytes),
                    clashSelection: clash?.selection(at: date, bytes: bytes), isInterface: isInterface)
                let tooltipSize = CGSize(width: min(UsageTimelineTooltip.width, max(0, size.width - 8)), height: tooltip.height)
                let origin = ChartTooltipLayout.origin(at: point, size: tooltipSize, bounds: bounds)
                tooltip
                    .frame(width: tooltipSize.width, height: tooltipSize.height, alignment: .topLeading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.12)))
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                    .offset(x: origin.x, y: origin.y).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    private func edge(_ slot: UsageTimeSlot, direction: UsageDirection, trailing: Bool) -> Date {
        let fraction: Double = direction == .upload ? (trailing ? 0.44 : 0.08) : (trailing ? 0.92 : 0.56)
        return slot.start.addingTimeInterval(slot.end.timeIntervalSince(slot.start) * fraction)
    }
    private func center(_ slot: UsageTimeSlot, direction: UsageDirection) -> Date {
        slot.start.addingTimeInterval(slot.end.timeIntervalSince(slot.start) * (direction == .upload ? 0.26 : 0.74))
    }
    private func color(_ id: String) -> Color { UsageChartPalette.color(id, sources: data.sources.map(\.id)) }
    private func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
    private func axisBytes(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < Double(Int64.max) else { return "—" }
        return UsageFormatter.bytes(Int64(value))
    }
}
