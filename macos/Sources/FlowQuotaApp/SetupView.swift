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
            step("2", title: "启用本地采样服务", detail: "启用服务后查看真实采样状态。普通网络不自动计量，网络状态未知时不自动累计；可手动标记当前连接。高成本网络不等于已确认的手机热点。VPN 或路由归属不明确时，接口总量可能不可用，请查看接口服务说明。")
            MonitoringBanner(state: state)
            step("3", title: "本地通知", detail: "应用列表使用 nettop 归因，可能重叠，不相加作为接口总量。接口每日／短时预警独立于应用归因；每个应用／服务另有短时阈值，列表中的应用可设置每日阈值。允许通知后由主应用投递，关闭面板仍继续，需保留主应用运行。")
            NotificationPermissionView(permission: state.notifications)
            step("4", title: "检查开机启动", detail: "在设置页查看真实的系统注册状态，并自行选择是否启用。")
            Text("本版本只采样与提醒，不自动阻断。退出应用会请求停止采集，再等待服务确认。")
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
