import SwiftUI

/// Complete, scrollable evidence instead of discarding low-ranked sources.
/// Clash children and residual replace the kernel, preserving its complete use.
struct TrafficSourceDetailsView: View {
    let processes: ApplicationTimelinePresentation?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("流量来源明细").font(.headline)
            if let processes, processes.summary.totalBytes != nil {
                rows(processes.sources)
            } else {
                Text("应用用量未观测，来源待确认；接口记录仍完整展示。")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let notice = processes?.clashNotice {
                Text(notice).font(.caption).foregroundStyle(.orange)
            }
        }
        .flowQuotaCard()
    }

    private func rows(_ sources: [UsageApplicationSource]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("应用／系统服务").frame(maxWidth: .infinity, alignment: .leading)
                column("上传")
                column("下载")
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(sources) { source in
                        HStack(alignment: .top) {
                            Text(source.name).frame(maxWidth: .infinity, alignment: .leading)
                                .help(source.id)
                            column(UsageFormatter.bytes(source.uploadedBytes))
                            column(UsageFormatter.bytes(source.downloadedBytes))
                        }
                        .font(.caption).textSelection(.enabled)
                    }
                }
                .padding(.top, 8)
            }
            .frame(height: min(260, CGFloat(sources.count) * 30 + 8))
        }
    }

    private func column(_ text: String) -> some View {
        Text(text).monospacedDigit().frame(width: 82, alignment: .trailing)
    }
}
