import SwiftUI

/// Complete, scrollable evidence instead of discarding low-ranked sources.
/// Clash child observations have their own section and are never summed with the kernel.
struct TrafficSourceDetailsView: View {
    let processes: ApplicationTimelinePresentation?
    let clash: ApplicationTimelinePresentation?
    let total: UsageTimelineData?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("应用／进程用量明细").font(.headline)
            Text("对应上方所选时段；代理内核的来源应用未完全确认，仍保留全部进程用量。")
                .font(.caption).foregroundStyle(.secondary)
            if let processes, processes.summary.totalBytes != nil {
                rows(processes.sources)
            } else {
                Text("应用用量未观测，来源待确认；接口记录仍完整展示。")
                    .font(.caption).foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("上传核对").font(.caption.weight(.semibold))
                TrafficMeasurementStatus(total: total?.uploadedBytes, processes: processes?.summary.uploadedBytes)
                Text("下载核对").font(.caption.weight(.semibold))
                TrafficMeasurementStatus(total: total?.downloadedBytes, processes: processes?.summary.downloadedBytes)
            }
            if let clash, !clash.sources.isEmpty {
                DisclosureGroup("Clash 识别来源（辅助线索，不与代理内核相加）") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("这些记录不能与代理内核或其他进程再次相加；缺失的连接无法事后补认应用。")
                            .font(.caption).foregroundStyle(.secondary)
                        rows(clash.sources)
                        if let notice = clash.clashNotice {
                            Text(notice).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if let notice = clash?.clashNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
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
