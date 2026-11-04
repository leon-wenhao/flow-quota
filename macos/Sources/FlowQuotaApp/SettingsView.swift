import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let state: AppState
    @AppStorage("showMenuBarUsage") private var showMenuBarUsage = true
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginBusy = false
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("设置", systemImage: "gearshape").font(.title2.bold())
            Toggle("在菜单栏显示用量文字", isOn: $showMenuBarUsage)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label("开机启动：\(loginDescription)", systemImage: "power")
                Text("状态直接读取自系统。启用可能需要应用签名、完整 app 包及系统批准。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(loginStatus == .enabled ? "关闭开机启动" : "启用开机启动") { changeLoginStatus() }
                        .disabled(loginBusy || loginStatus == .requiresApproval || !isAppBundle)
                    Button("系统登录项设置", systemImage: "arrow.up.forward.app") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
                if !isAppBundle {
                    Text("命令行二进制无法配置开机启动；请运行完整的 Flow Quota.app。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let loginError {
                    Label(loginError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                }
            }
            Divider()
            ProtectionBanner(state: state)
            Button("重新读取服务状态", systemImage: "arrow.clockwise") {
                state.refreshOnce()
                loginStatus = SMAppService.mainApp.status
            }
            .disabled(state.busy || state.refreshing)
            if Bundle.main.object(forInfoDictionaryKey: "FlowQuotaDevelopmentBuild") as? Bool == true {
                Button("修复开发服务", systemImage: "wrench.and.screwdriver") { state.repairDevelopmentAgent() }
                    .disabled(state.busy)
                Text("仅用于重新构建后遗留的开发服务。平台接口会检查开发包标记及系统扩展目录；系统批准仍需手动完成。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("若系统要求批准，请在系统设置中允许后台服务与网络扩展，再重新读取状态。此界面不会自动安装或批准扩展。")
                .font(.caption).foregroundStyle(.secondary)
            NotificationPermissionView(permission: state.notifications)
            Text("额度、日期切换与持久化由保护服务管理。应用额度不等于运营商计费；协议开销、重传和在途数据可能产生额外用量。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { loginStatus = SMAppService.mainApp.status }
    }

    private var isAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    private var loginDescription: String {
        switch loginStatus {
        case .enabled: return "已注册"
        case .notRegistered: return "未注册"
        case .requiresApproval: return "等待系统批准"
        case .notFound: return "系统未找到应用"
        @unknown default: return "未知"
        }
    }
    private func changeLoginStatus() {
        guard !loginBusy else { return }
        loginBusy = true
        loginError = nil
        Task { @MainActor in
            defer { loginBusy = false; loginStatus = SMAppService.mainApp.status }
            do {
                if loginStatus == .enabled { try await SMAppService.mainApp.unregister() }
                else { try SMAppService.mainApp.register() }
            } catch { loginError = "无法更改开机启动：\(error.localizedDescription)" }
        }
    }
}
