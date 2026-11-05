import SwiftUI

struct UsageDetailsView: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("用量详情").font(.title2.bold())
            MonitoringBanner(state: state)
            SettingsSection(title: "当前网络") {
                Label(state.networkName, systemImage: "network")
                Text(state.networkDetail).font(.caption).foregroundStyle(.secondary)
            }
            SettingsSection(title: "接口计量") { InterfaceUsageSummary(state: state) }
            UsageChartsView(state: state)
            if let sampledAt = state.snapshot?.sampledAt {
                Text("应用最近采样：\(sampledAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
