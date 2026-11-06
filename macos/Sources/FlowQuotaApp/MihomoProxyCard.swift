import FlowQuotaCore
import SwiftUI

/// Diagnostics only. Source traffic belongs in the shared application list.
struct MihomoProxyCard: View {
    let proxy: MihomoProxySnapshot

    private var statusTitle: String {
        switch proxy.status {
        case .paused: "Flow Quota 来源采集已暂停"
        case .observing: "来源识别 API 已连接"
        case .stale: "来源识别 API 暂不可用"
        case .unavailable: "等待来源识别 API"
        }
    }

    var body: some View {
        SettingsSection(title: "Clash 来源识别诊断") {
            Label(statusTitle, systemImage: "arrow.triangle.branch")
            Text(proxy.message).font(.caption).foregroundStyle(.secondary)
            Text("Clash 标签表示连接由 Mihomo 处理，含 DIRECT 规则；不表示必经代理节点。采集状态指 Flow Quota，不是 Clash 的开关状态。")
                .font(.caption).foregroundStyle(.secondary)
            Text("来源明细见应用用量列表；只计本次服务运行期间的连续观测，服务重启后重新开始，不补算未知区间。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
