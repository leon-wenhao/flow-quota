import FlowQuotaCore
import SwiftUI

struct ClashSourceRow: View {
    let source: MihomoProxySource
    let usage: Int64?
    let status: MihomoProxyStatus
    var compact = false
    @State private var showsDetails = false

    private var subtitle: String {
        let app = source.siteName == nil ? nil : source.appIdentity?.name
        let activity = switch status {
        case .observing: "\(source.connectionCount) 条活动连接"
        case .paused: "来源采集已暂停"
        case .stale, .unavailable: "API 暂不可用，累计保留"
        }
        return [app, activity].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        Button { showsDetails = true } label: {
            TrafficSourceRowContent(name: source.displayName, symbol: "arrow.triangle.branch",
                status: subtitle, usage: UsageFormatter.bytes(usage), scope: "代理内的辅助明细", compact: compact)
        }
        .buttonStyle(FlowQuotaRowButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("查看 Clash 来源识别与计量范围")
        .popover(isPresented: $showsDetails) {
            VStack(alignment: .leading, spacing: 10) {
                Text(source.displayName).font(.headline)
                if let app = source.appIdentity?.name { Text("来源应用：\(app)") }
                Text("上传：\(UsageFormatter.bytes(usage == nil ? nil : source.uploadedBytes))")
                Text("下载：\(UsageFormatter.bytes(usage == nil ? nil : source.downloadedBytes))")
                Text("Clash 标签表示连接由 Clash/Mihomo 处理，包含其 DIRECT 直连规则；不代表一定经过代理节点。")
                Text("依据 API 的域名与进程路径归因；站点未确认时回退为应用名称。只累计本次服务运行期间的连续观测，暂停和故障区间未知；服务重启后从零重新观测。")
                Text("这是代理连接明细，可能与应用每日归因重叠，不与接口总量相加，也不作为独立每日额度。")
            }
            .font(.caption).textSelection(.enabled).padding(16).frame(width: 340)
        }
    }
}
