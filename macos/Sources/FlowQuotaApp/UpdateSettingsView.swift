import SwiftUI

struct UpdateSettingsView: View {
    let state: AppState
    private var updater: AppUpdater { state.updater }

    var body: some View {
        SettingsSection(title: "软件更新") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("自动检查新版本").frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("自动检查新版本", isOn: Binding(
                        get: { updater.automaticChecks.enabled },
                        set: { updater.automaticChecks.setEnabled($0) }))
                        .labelsHidden().toggleStyle(FlowQuotaToggleStyle()).fixedSize()
                }
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("当前版本")
                        Text(updater.currentVersion)
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    Button("检查更新", systemImage: "arrow.triangle.2.circlepath") { updater.check() }
                        .settingsAction()
                        .disabled(!updater.canCheck || state.busy)
                }
                Text(updater.message).font(.caption).foregroundStyle(.secondary)
                if let error = updater.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if let date = updater.lastCheck {
                    Text("上次检查：\(date.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if updater.hasPendingInstall && !updater.installing {
                    Button("重试安装") { updater.prepareInstallation() }
                        .settingsAction().disabled(state.busy)
                }
                if updater.needsRecovery && !updater.installing {
                    HStack {
                        Button("恢复更新前的采集状态") {
                            Task { await updater.recover(allowStale: true) }
                        }.settingsAction()
                        Button("保持暂停并清除恢复标记") {
                            Task { await updater.recover(discard: true) }
                        }.settingsAction()
                    }.disabled(state.busy)
                }
            }.padding(.top, 2)
        }
    }
}
