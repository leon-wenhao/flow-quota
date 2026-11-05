import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let state: AppState
    @AppStorage("showMenuBarUsage") private var showMenuBarUsage = true
    @AppStorage(UsageRefreshPreference.key) private var usageRefreshSeconds = UsageRefreshPreference.defaultSeconds
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设置").font(.title2.bold())
            MonitoringBanner(state: state)
            SettingsSection(title: "通用") {
                Toggle(isOn: $showMenuBarUsage) {
                    Text("菜单栏显示用量").frame(maxWidth: .infinity, alignment: .leading)
                }
                    .toggleStyle(.switch).controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .help("显示今日计量接口的上传与下载总量")
                Divider()
                usageRefreshSetting
                Divider()
                loginItem
            }
            UpdateSettingsView(state: state)
            SettingsSection(title: "提醒") {
                NotificationPermissionView(permission: state.notifications)
                if let policy = state.snapshot?.trafficAlertPolicy {
                    Divider()
                    TrafficAlertSettingsView(state: state, policy: policy)
                }
            }
            serviceTools
            measurementNotes
        }
        .onAppear { loginStatus = SMAppService.mainApp.status }
    }

    private var displayedRefreshSeconds: Int {
        UsageRefreshPreference.allowedSeconds.contains(usageRefreshSeconds)
            ? usageRefreshSeconds : UsageRefreshPreference.defaultSeconds
    }

    private var usageRefreshSetting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Stepper(value: Binding(
                get: { displayedRefreshSeconds },
                set: { usageRefreshSeconds = $0 }
            ), in: UsageRefreshPreference.allowedSeconds) {
                Text("用量刷新间隔：\(displayedRefreshSeconds) 秒")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityLabel("用量刷新间隔")
            Text("可设 1–5 秒，自动保存，从下一轮等待生效。影响界面、菜单栏和通知检查；后台仍约每 2 秒采样。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var loginItem: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { loginStatus == .enabled },
                set: { changeLoginStatus(enabled: $0) }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("开机启动")
                    Text(loginDescription).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch).controlSize(.small)
            .frame(maxWidth: .infinity)
            .disabled(!canChangeLoginStatus)
            if loginStatus == .requiresApproval || loginStatus == .notFound {
                Button("前往设置") { SMAppService.openSystemSettingsLoginItems() }
                    .settingsAction()
            }
            if !isAppBundle {
                Text("请运行完整 app 以配置开机启动。")
                    .font(.caption).foregroundStyle(.secondary)
            }

        }
    }

    private var serviceTools: some View {
        DisclosureGroup("服务与诊断") {
            VStack(alignment: .leading, spacing: 10) {
                Button("刷新服务状态", systemImage: "arrow.clockwise") {
                    state.refreshOnce()
                    loginStatus = SMAppService.mainApp.status
                }
                .settingsAction()
                .disabled(state.busy || state.refreshing)
                Button("系统登录项设置", systemImage: "arrow.up.forward.app") {
                    SMAppService.openSystemSettingsLoginItems()
                }
                .settingsAction()
                Text("若需要系统批准，请在登录项设置中允许后台服务，再刷新状态。")
                    .font(.caption).foregroundStyle(.secondary)
                if Bundle.main.object(forInfoDictionaryKey: "FlowQuotaDevelopmentBuild") as? Bool == true {
                    Divider()
                    Button("修复开发服务", systemImage: "wrench.and.screwdriver") { state.repairDevelopmentAgent() }
                        .settingsAction()
                        .disabled(state.busy)
                    Text("仅用于重新构建后的开发服务；系统批准仍需手动完成。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        }
        .font(.subheadline)
    }

    private var measurementNotes: some View {
        DisclosureGroup("计量说明") {
            VStack(alignment: .leading, spacing: 8) {
                Text("高成本网络自动计量；手动热点共用同一每日预算。高成本信号不代表已确认手机热点。")
                Text("总量来自单个物理接口的上传＋下载，包含局域网流量与协议开销；不含手机自身或其他设备，不等于运营商账单。应用归因可能重叠，不相加作为总量。")
                Text("仅累计服务运行期间的观测增量；启动前、暂停和采样间断的流量未知，不回填。接口不可用时可保留当日累计。")
                Text("接口每日、接口短时、各应用／服务短时预警独立判断；应用每日提醒继续保留。阈值保存只表示配置已持久化，不会阻断连接。")
            }
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            .padding(.top, 8)
        }
        .font(.subheadline)
    }

    private var isAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    private var loginDescription: String {
        switch loginStatus {
        case .enabled: return "已开启"
        case .notRegistered: return "未开启"
        case .requiresApproval: return "等待系统批准"
        case .notFound: return "系统未找到应用"
        @unknown default: return "状态未知"
        }
    }
    private var canChangeLoginStatus: Bool {
        isAppBundle && !loginBusy && (loginStatus == .enabled || loginStatus == .notRegistered)
    }

    private func changeLoginStatus(enabled: Bool) {
        guard canChangeLoginStatus, enabled != (loginStatus == .enabled) else { return }
        loginBusy = true
        state.clearMessages()
        Task { @MainActor in
            defer { loginBusy = false; loginStatus = SMAppService.mainApp.status }
            do {
                // The switch reflects system confirmation, never a locally saved promise.
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
            } catch { state.reportError("无法更改开机启动：\(error.localizedDescription)") }
        }
    }
}
