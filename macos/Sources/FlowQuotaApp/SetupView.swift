import SwiftUI

struct SetupView: View {
    let state: AppState
    let continueToOverview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("本地流量额度", systemImage: "internaldrive").font(.title2.bold())
            Text("规则、当前日用量和通知状态只留在本机。无需账户，不上传流量内容、网址或聊天记录。")
                .font(.body)
            step("1", title: "了解计量范围", detail: "V1 只在热点或手动标记的当前连接下计量。普通网络不消耗热点额度。")
            step("2", title: "启用服务与保护组件", detail: "先启用本地服务；按系统提示批准后台服务、系统扩展和网络过滤。服务连接成功不等于网络保护已经生效。")
            ProtectionBanner(state: state)
            step("3", title: "本地通知", detail: "可自愿授权提醒与声音。保护服务负责真实额度事件；拒绝通知不影响计量与阻断。")
            NotificationPermissionView(permission: state.notifications)
            step("4", title: "检查开机启动", detail: "在设置页查看真实的系统注册状态，并自行选择是否启用。")
            Text("当前构建尚未完成真实网络保护验收。若组件未安装或未批准，面板会持续显示未就绪。")
                .font(.caption).foregroundStyle(.secondary)
            Button("了解，查看用量面板", systemImage: "arrow.right") { continueToOverview() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func step(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).font(.headline).frame(width: 24, height: 24)
                .background(.quaternary, in: Circle()).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
