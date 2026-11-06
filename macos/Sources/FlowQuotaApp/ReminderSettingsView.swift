import SwiftUI

struct ReminderSettingsView: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("预警设置").flowQuotaPageTitle()
            SettingsSection(title: "系统通知") {
                NotificationPermissionView(permission: state.notifications)
            }
            if let policy = state.categoryPolicy {
                TrafficAlertSettingsView(state: state, policy: policy)
            } else {
                Text("预警配置尚未就绪，请连接服务后刷新。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let warning = state.trafficAlertWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
    }
}
