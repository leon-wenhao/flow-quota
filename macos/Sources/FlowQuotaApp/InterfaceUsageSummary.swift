import SwiftUI

struct InterfaceUsageSummary: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("今日计量接口总量").font(.subheadline).foregroundStyle(.secondary)
            Text(UsageFormatter.bytes(state.totalUsage))
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .accessibilityLabel("今日计量接口总量：\(UsageFormatter.bytes(state.totalUsage))")
            Text(state.interfaceUsageReason).font(.caption).foregroundStyle(.secondary)
            Text("接口服务说明：\(state.interfaceServiceMessage)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("本机物理网络接口上传＋下载的观测增量，包含局域网流量与协议开销；不含手机自身或其他设备的流量，不等于运营商账单。仅累计高成本／手动热点网络的连续观测区间。")
                .font(.caption).foregroundStyle(.secondary)
            Text("VPN 或路由归属不明确时，接口总量可能不可用；不会改用应用用量相加。")
                .font(.caption).foregroundStyle(.secondary)
            Text(state.interfaceSampleTimeText).font(.caption2).foregroundStyle(.secondary)
            if let date = state.snapshot?.generatedAt {
                Text("服务快照：\(date.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
