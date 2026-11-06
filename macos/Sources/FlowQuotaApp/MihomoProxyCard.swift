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
            Text("来源分钟汇总保留在本机当天账本，服务重启后仍可查看。此诊断状态及活动连接只代表本次运行；间断不补量，非当前日数据统一清理。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
