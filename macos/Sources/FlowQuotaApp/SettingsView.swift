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
            Text("通用设置").flowQuotaPageTitle()
            MonitoringBanner(state: state)
            SettingsSection(title: "通用") {
                AppearanceSettingsView()
                HStack {
                    Text("菜单栏显示用量").frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("菜单栏显示用量", isOn: $showMenuBarUsage)
                        .labelsHidden().toggleStyle(FlowQuotaToggleStyle()).fixedSize()
                }
                .padding(.vertical, 3)
                    .help("菜单栏以 626M、1.2G 等紧凑形式显示今日接口总量；关闭后仅显示图标。悬停可查看完整信息。")
                usageRefreshSetting
                loginItem
            }
            networkClassification
            UpdateSettingsView(state: state)
            serviceTools
        }
        .onAppear { loginStatus = SMAppService.mainApp.status }
    }

    private var displayedRefreshSeconds: Int {
        UsageRefreshPreference.allowedSeconds.contains(usageRefreshSeconds)
            ? usageRefreshSeconds : UsageRefreshPreference.defaultSeconds
    }

    private var usageRefreshSetting: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowQuotaStepper(title: "用量刷新间隔", suffix: "秒", value: Binding(
                get: { displayedRefreshSeconds },
                set: { usageRefreshSeconds = $0 }
            ), range: UsageRefreshPreference.allowedSeconds.first!...UsageRefreshPreference.allowedSeconds.last!,
            layout: .inline)
            .accessibilityLabel("用量刷新间隔")
        }
    }

    private var loginItem: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("开机启动")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("开机启动", isOn: Binding(
                    get: { loginStatus == .enabled },
                    set: { changeLoginStatus(enabled: $0) }
                ))
                .labelsHidden().toggleStyle(FlowQuotaToggleStyle()).fixedSize()
            }
            .padding(.vertical, 3)
            .disabled(!canChangeLoginStatus)
            if loginStatus == .requiresApproval || loginStatus == .notFound {
                Label(loginStatus == .requiresApproval ? "等待系统批准" : "系统未找到应用", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
                Button("前往设置") { SMAppService.openSystemSettingsLoginItems() }
                    .settingsAction()
            }
            if !isAppBundle {
                Text("请运行完整 app 以配置开机启动。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var networkClassification: some View {
        DisclosureGroup("网络分类修正") {
            VStack(alignment: .leading, spacing: 8) {
                Label(state.networkName, systemImage: "network")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(state.networkDetail)
                if state.showsHotspotControl {
                    HStack(spacing: 12) {
                        Text("手动热点").frame(maxWidth: .infinity, alignment: .leading)
                        Toggle("手动热点", isOn: Binding(
                            get: { state.hotspotMarked },
                            set: { state.setHotspotOverride($0) }
                        ))
                        .labelsHidden().toggleStyle(FlowQuotaToggleStyle()).fixedSize()
                        .disabled(!state.canConfigureNetwork)
                        .help(state.networkDetail)
                    }
                    .padding(.vertical, 3)
                    if !state.networkUnavailableReason.isEmpty {
                        Text(state.networkUnavailableReason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 8)
        }
        .font(.subheadline)
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
                if Bundle.main.object(forInfoDictionaryKey: "FlowQuotaDevelopmentBuild") as? Bool == true {
                    Divider()
                    Button("修复开发服务", systemImage: "wrench.and.screwdriver") { state.repairDevelopmentAgent() }
                        .settingsAction()
                        .disabled(state.busy)
                }
            }
            .padding(.top, 8)
        }
        .font(.subheadline)
    }

    private var isAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }
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
