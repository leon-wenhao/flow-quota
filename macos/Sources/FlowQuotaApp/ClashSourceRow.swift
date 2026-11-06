import FlowQuotaCore
import SwiftUI

struct ClashSourceRow: View {
    let source: MihomoProxySource
    let usage: Int64?
    let status: MihomoProxyStatus
    var compact = false
    @State private var showsDetails = false

    private var subtitle: String {
        source.id == ClashUsageBreakdown.unknownID ? "已记录用量，具体来源未识别" : "经 Clash 处理的流量"
    }

    var body: some View {
        Button { showsDetails = true } label: {
            TrafficSourceRowContent(name: source.displayName, symbol: "arrow.triangle.branch",
                status: subtitle, usage: UsageFormatter.bytes(usage), scope: "Clash 来源", compact: compact)
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
                Text("来源由已记录的当天分钟观测拆分，已识别部分保留原数，余量归入其他未识别；暂停、重启和故障间断不补量。")
                Text("这些来源合计保留已观测的 Clash 内核用量，内核父项不再重复列出。每日提醒仍按内核整体设置；来源不是独立额度身份。")
            }
            .font(.caption).textSelection(.enabled).padding(16).frame(width: 340)
        }
    }
}
