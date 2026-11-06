import SwiftUI

struct UsageDetailsView: View {
    let state: AppState
    let showCharts: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("用量详情").flowQuotaPageTitle()
            MonitoringBanner(state: state)
            SettingsSection(title: "当前网络") {
                Label(state.networkName, systemImage: "network")
                Text(state.networkDetail).font(.caption).foregroundStyle(.secondary)
            }
            SettingsSection(title: "接口计量") { InterfaceUsageSummary(state: state) }
            Button(action: showCharts) { Label("查看用量图表", systemImage: "chart.pie") }
                .settingsAction()
            if let sampledAt = state.categorySnapshot?.sampledAt {
                Text("应用最近采样：\(sampledAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
