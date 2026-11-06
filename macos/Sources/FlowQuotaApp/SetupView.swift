import SwiftUI

struct SetupView: View {
    let state: AppState
    let continueToOverview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("本地流量采样与提醒", systemImage: "internaldrive").font(.title2.bold())
            Text("规则、当前日用量和通知状态只留在本机。无需账户，不上传流量内容、网址或聊天记录。")
                .font(.body)
            step("1", title: "了解计量范围", detail: "顶部为独立的本机物理接口上传＋下载观测总量，含局域网流量与协议开销，不含手机自身或其他设备流量，也不是运营商账单。高成本网络自动计量，手动热点计入同一当日累计。启动、切网、跨日和采样间断会重建基线，不追溯未知流量。")
            step("2", title: "启用本地采样服务", detail: "启用服务后查看真实采样状态。热点／高成本与普通网络分别统计和设置提醒，普通网络提醒默认关闭。网络未知时不分配新增流量；手动热点可修正当前分类。高成本网络不等于已确认的手机热点。VPN 或路由归属不明确时，接口总量可能不可用，请查看接口服务说明。")
            MonitoringBanner(state: state)
            step("3", title: "本地通知", detail: "总流量由物理接口采样，列表显示应用和 Clash 来源；无法识别的 Clash 部分完整保留。接口每日／短时预警独立判断；每个应用／服务另有短时阈值，列表中的应用可设置每日阈值，Clash 整体阈值在用量详情中设置。允许通知后由主应用投递，关闭面板仍继续，需保留主应用运行。")
            NotificationPermissionView(permission: state.notifications)
            step("4", title: "检查开机启动", detail: "在“通用设置”中选择是否登录时启动；若系统要求批准，页面会显示处理入口。")
            SettingsUsageGuide()
            Text("本版本只采样与提醒，不自动阻断。退出应用会请求停止采集，再等待服务确认。")
                .font(.caption).foregroundStyle(.secondary)
            Button("了解，查看用量面板", systemImage: "arrow.right") { continueToOverview() }
                .settingsAction(prominent: true)
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
