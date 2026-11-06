import SwiftUI

/// The pies use process observations only. Clash children are separately inspectable.
struct UsageChartsView: View {
    let data: ApplicationTimelinePresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("进程观测比例（非 Mac 总量分摊）").font(.subheadline.weight(.semibold))
            HStack(alignment: .top, spacing: 20) {
                UsagePieChart(data: data.pie(.upload), title: "上传", sourceIDs: data.sources.map(\.id))
                UsagePieChart(data: data.pie(.download), title: "下载", sourceIDs: data.sources.map(\.id))
            }
            Text("包含代理内核的完整观测；可能与应用重复。Clash 来源线索单独展示，不重复加入饼图。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .flowQuotaCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("所选时段的进程观测比例，包含代理内核，不代表接口总量分摊")
    }
}
