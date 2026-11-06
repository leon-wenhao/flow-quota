import SwiftUI

/// Source ranking and directional distributions use the same complete display-source set.
struct UsageChartsView: View {
    let data: ApplicationTimelinePresentation
    var chartHeight: CGFloat = 174

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            UsageSourceBarChart(data: data)
            Divider()
            HStack(alignment: .top, spacing: 20) {
                UsagePieChart(data: data.pie(.upload), title: "上传", sourceIDs: data.sources.map(\.id), chartHeight: chartHeight)
                UsagePieChart(data: data.pie(.download), title: "下载", sourceIDs: data.sources.map(\.id), chartHeight: chartHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .flowQuotaCard(padding: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("所选时段各流量来源的上传和下载分布")
    }
}
