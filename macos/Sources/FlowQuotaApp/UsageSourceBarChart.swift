import SwiftUI

/// A compact horizontal stacked chart for every positive source in the selected interval.
/// It keeps all sources available without turning the page into a plain text table.
struct UsageSourceBarChart: View {
    let data: ApplicationTimelinePresentation

    private let uploadColor = UsageChartPalette.colors[0]
    private let downloadColor = UsageChartPalette.colors[1]
    private let sourceColumnWidth: CGFloat = 142
    private let totalColumnWidth: CGFloat = 72

    private var sources: [UsageApplicationSource] {
        data.sources.filter { $0.uploadedBytes > 0 || $0.downloadedBytes > 0 }
    }

    private var maximumBytes: Int64 {
        sources.compactMap { UsageFormatter.total([$0.uploadedBytes, $0.downloadedBytes]) }.max() ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("所选时段来源排行")
                        .font(.headline)
                    Text("全部有流量来源 · 按上传＋下载降序")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                legend
            }

            if sources.isEmpty {
                Text("所选时段没有正向应用来源观测；接口总量仍单独统计。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
            } else {
                HStack(spacing: 8) {
                    Text("来源").frame(width: sourceColumnWidth, alignment: .leading)
                    Text(UsageFormatter.bytes(maximumBytes)).frame(maxWidth: .infinity, alignment: .trailing)
                    Text("合计").frame(width: totalColumnWidth, alignment: .trailing)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(sources) { source in
                            row(source)
                        }
                    }
                }
                .frame(maxHeight: 268)
                .scrollIndicators(.automatic)
            }

            if let notice = data.clashNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("所选时段全部来源排行")
    }

    private var legend: some View {
        HStack(spacing: 10) {
            legendItem(color: uploadColor, title: "上传")
            legendItem(color: downloadColor, title: "下载")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func legendItem(color: Color, title: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
        }
    }

    private func row(_ source: UsageApplicationSource) -> some View {
        let total = UsageFormatter.total([source.uploadedBytes, source.downloadedBytes]) ?? 0
        return HStack(spacing: 8) {
            Text(source.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: sourceColumnWidth, alignment: .leading)
                .help(source.id)

            GeometryReader { geometry in
                let width = max(0, geometry.size.width)
                let uploadWidth = width * CGFloat(Double(source.uploadedBytes) / Double(maximumBytes))
                let downloadWidth = width * CGFloat(Double(source.downloadedBytes) / Double(maximumBytes))
                HStack(spacing: 0) {
                    Rectangle().fill(uploadColor).frame(width: uploadWidth)
                    Rectangle().fill(downloadColor).frame(width: downloadWidth)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .clipShape(Capsule())
                .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            .frame(height: 12)

            Text(UsageFormatter.bytes(total))
                .font(.caption)
                .monospacedDigit()
                .frame(width: totalColumnWidth, alignment: .trailing)
        }
        .font(.caption)
        .frame(minHeight: 24)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(source.name)
        .accessibilityValue("上传 \(UsageFormatter.bytes(source.uploadedBytes))，下载 \(UsageFormatter.bytes(source.downloadedBytes))，合计 \(UsageFormatter.bytes(total))")
    }
}
