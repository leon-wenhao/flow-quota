import SwiftUI

/// Directional pies share the timeline's interval, source set and colors.
struct UsageChartsView: View {
    let data: ApplicationTimelinePresentation

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            UsagePieChart(data: data.pie(.upload), title: "上传", sourceIDs: data.sources.map(\.id))
            UsagePieChart(data: data.pie(.download), title: "下载", sourceIDs: data.sources.map(\.id))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .flowQuotaCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("所选时段的上传与下载应用占比")
    }
}
