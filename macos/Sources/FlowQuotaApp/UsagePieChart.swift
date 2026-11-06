import Charts
import SwiftUI

enum UsageChartPalette {
    // Ten distinct swatches, shared by every chart; gray is reserved for remaining.
    static let colors: [Color] = [
        Color(red: 0.22, green: 0.48, blue: 0.90), Color(red: 0.08, green: 0.65, blue: 0.63),
        Color(red: 0.96, green: 0.59, blue: 0.20), Color(red: 0.60, green: 0.42, blue: 0.82),
        Color(red: 0.88, green: 0.35, blue: 0.55), Color(red: 0.45, green: 0.67, blue: 0.22),
        Color(red: 0.20, green: 0.67, blue: 0.85), Color(red: 0.72, green: 0.51, blue: 0.32),
        Color(red: 0.85, green: 0.43, blue: 0.25), Color(red: 0.53, green: 0.56, blue: 0.80)
    ]
    static func color(_ id: String, sources: [String]) -> Color {
        id == "remaining" ? .gray : colors[(sources.firstIndex(of: id) ?? 0) % colors.count]
    }
}

enum PieHoverSelection {
    static func isInRing(_ point: CGPoint, plot: CGRect) -> Bool {
        let radius = min(plot.width, plot.height) / 2
        let distance = hypot(point.x - plot.midX, point.y - plot.midY)
        return radius > 0 && distance >= radius * 0.6 && distance <= radius
    }

    static func slice(at value: Double, data: UsagePieData) -> UsagePieSlice? {
        guard value.isFinite, value >= 0, value < Double(data.totalBytes) else { return nil }
        var upper: Double = 0
        for slice in data.slices {
            upper += Double(slice.bytes)
            if value < upper { return slice }
        }
        return nil
    }
}

struct UsagePieChart: View {
    let data: UsagePieData
    let title: String
    var sourceIDs: [String] = []
    var chartHeight: CGFloat = 174
    @Environment(\.chartTooltipViewport) private var tooltipViewport
    @State private var hoverPoint: CGPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold))
            if data.totalBytes == 0 {
                Text("已观测用量为 0 B").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: chartHeight)
            } else {
                Chart(data.slices) { item in
                    // Gaps can erase tiny slices; keep exact proportions and contiguous colors.
                    SectorMark(angle: .value("字节", Double(item.bytes)), innerRadius: .ratio(0.6), angularInset: 0)
                        .foregroundStyle(UsageChartPalette.color(item.id, sources: sourceIDs.isEmpty ? data.slices.map(\.id) : sourceIDs))
                        .accessibilityLabel(item.label)
                        .accessibilityValue(description(item))
                }
                .chartLegend(.hidden)
                .frame(height: chartHeight)
                .chartBackground { _ in
                    Text(UsageFormatter.bytes(data.totalBytes)).font(.caption.bold()).monospacedDigit()
                        .allowsHitTesting(false)
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        if let anchor = proxy.plotFrame {
                            overlay(proxy: proxy, plot: geometry[anchor], size: geometry.size,
                                bounds: ChartTooltipLayout.visibleBounds(chartFrame: geometry.frame(in: .global), viewport: tooltipViewport))
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(title)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onChange(of: data) { _, _ in hoverPoint = nil }
        .onDisappear { hoverPoint = nil }
    }

    private func overlay(proxy: ChartProxy, plot: CGRect, size: CGSize, bounds: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverPoint = PieHoverSelection.isInRing(point, plot: plot) ? point : nil
                case .ended: hoverPoint = nil
                }
            }
            if let point = hoverPoint,
               let relative = ChartTooltipLayout.plotLocation(point, in: plot),
               let value: Double = proxy.value(atAngle: proxy.angle(at: relative)),
               let item = PieHoverSelection.slice(at: value, data: data) {
                let tooltipSize = CGSize(width: min(184, max(0, size.width - 8)), height: 68)
                let origin = ChartTooltipLayout.origin(at: point, size: tooltipSize, bounds: bounds)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.label).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(UsageFormatter.bytes(item.bytes)).font(.caption).monospacedDigit()
                }
                .padding(10)
                .frame(width: tooltipSize.width, height: tooltipSize.height, alignment: .topLeading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                .offset(x: origin.x, y: origin.y).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    private func description(_ item: UsagePieSlice) -> String { UsageFormatter.bytes(item.bytes) }
}
