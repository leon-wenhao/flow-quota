import FlowQuotaCore
import SwiftUI

struct MonitoringBanner: View {
    let state: AppState

    private var presentation: MonitoringPresentation { MonitoringPresentation(state: state) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label {
                    Text(presentation.title).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: presentation.symbol).foregroundStyle(presentation.statusColor)
                }
                .font(.headline)
                Spacer()
                Button { state.refreshOnce() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("刷新采样状态").help("刷新采样状态")
                    .disabled(state.busy || state.refreshing)
            }
            Text(presentation.summary).font(.caption).foregroundStyle(.secondary)
            // Failures stay visible; normal service prose is available on demand.
            if presentation.showsFailureReason, let message = state.snapshot?.message, !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(presentation.failed ? Color.red : Color.secondary).textSelection(.enabled)
            }
            HStack {
                Text("流量采集").font(.subheadline)
                Spacer()
                SamplingControl(state: state)
            }
            DisclosureGroup("采样详情") {
                VStack(alignment: .leading, spacing: 6) {
                    if let message = state.snapshot?.message, !message.isEmpty, !presentation.showsFailureReason {
                        Text(message)
                    }
                    if let coverage = state.snapshot?.coverageMessage, !coverage.isEmpty {
                        Text(coverage)
                    }
                    Text("高成本网络自动计量；手动热点共用每日预算。仅提醒，不阻断连接。")
                }
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .padding(.top, 4)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(presentation.statusColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(presentation.statusColor.opacity(0.18)))
    }
}
