import FlowQuotaCore
import SwiftUI

struct UnidentifiedTrafficRow: View {
    let source: ReconciledTrafficSource
    var compact = false
    @State private var showsDetails = false

    var body: some View {
        Button { showsDetails = true } label: {
            TrafficSourceRowContent(name: source.name, symbol: "questionmark.circle",
                status: "接口总量中未能可靠归属", usage: UsageFormatter.bytes(source.totalBytes),
                scope: "核对余量", compact: compact)
        }
        .buttonStyle(FlowQuotaRowButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("查看未识别流量的计量说明")
        .popover(isPresented: $showsDetails) {
            VStack(alignment: .leading, spacing: 10) {
                Text(source.name).font(.headline)
                Text("上传：\(UsageFormatter.bytes(source.uploadedBytes))")
                Text("下载：\(UsageFormatter.bytes(source.downloadedBytes))")
                Text("这是物理接口父项中未能在同一分钟可靠对应到来源的部分。原始进程记录可能存在采样时间差、代理重叠或来源冲突，不能据此推断具体应用。")
            }
            .font(.caption).textSelection(.enabled).padding(16).frame(width: 340)
        }
    }
}
