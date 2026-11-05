import Charts
import FlowQuotaCore
import SwiftUI

struct UsageChartsView: View {
    let state: AppState

    private var data: UsageChartData {
        UsageChartData.make(interfaceUsage: state.totalUsage == nil ? nil : state.snapshot?.interfaceUsage,
                            applications: state.usageAvailable ? state.applications : [],
                            today: AppState.localDay(),
                            dailyInterfaceThreshold: state.totalUsage == nil ? nil : state.snapshot?.trafficAlertPolicy?.dailyInterfaceBytes)
    }

    var body: some View {
        SettingsSection(title: "用量图表") {
            VStack(alignment: .leading, spacing: 16) {
                interfaceChart
                applicationChart
                thresholdProgress
                Text("接口总量来自单个物理接口的独立计量；应用归因仅用于分析，可能重叠，不与接口总量相加。")
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var interfaceChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("接口上传与下载").font(.subheadline.weight(.semibold))
            if data.interfaceValues.isEmpty {
                chartUnavailable("当前没有可绘制的有效接口用量。")
            } else {
                Chart(data.interfaceValues) { item in
                    BarMark(
                        x: .value("字节", item.plottedValue),
                        y: .value("方向", item.label)
                    )
                    .foregroundStyle(item.id == "uploaded" ? Color.blue : Color.indigo)
                    .annotation(position: .trailing, alignment: .leading) {
                        Text(UsageFormatter.bytes(item.bytes))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .chartXAxis { AxisMarks { _ in AxisGridLine(); AxisValueLabel() } }
                .chartYAxis { AxisMarks { _ in AxisValueLabel() } }
                .chartLegend(.hidden)
                .frame(height: 88)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("接口上传与下载图表")
            }
        }
    }

    @ViewBuilder private var applicationChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("应用归因排行").font(.subheadline.weight(.semibold))
            if data.applicationValues.isEmpty {
                chartUnavailable("当前没有可绘制的应用归因用量。")
            } else {
                Chart(data.applicationValues) { item in
                    BarMark(
                        x: .value("字节", item.plottedValue),
                        y: .value("应用", item.label)
                    )
                    .foregroundStyle(Color.teal)
                    .annotation(position: .trailing, alignment: .leading) {
                        Text(UsageFormatter.bytes(item.bytes))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .chartXAxis { AxisMarks { _ in AxisGridLine(); AxisValueLabel() } }
                .chartYAxis { AxisMarks { _ in AxisValueLabel() } }
                .chartLegend(.hidden)
                .frame(height: max(92, CGFloat(data.applicationValues.count * 28)))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("应用归因排行图表")
            }
        }
    }

    @ViewBuilder private var thresholdProgress: some View {
        if let threshold = data.dailyInterfaceThreshold,
           let total = state.totalUsage,
           threshold > 0 {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("接口每日预警进度").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(UsageFormatter.bytes(total)) / \(UsageFormatter.bytes(threshold))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                ProgressView(value: min(Double(total) / Double(threshold), 1))
                    .tint(total >= threshold ? .orange : .accentColor)
                    .accessibilityLabel("接口每日预警进度")
                    .accessibilityValue("\(UsageFormatter.bytes(total))，阈值 \(UsageFormatter.bytes(threshold))")
            }
        }
    }

    private func chartUnavailable(_ message: String) -> some View {
        Text(message).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
    }
}
