import FlowQuotaCore
import SwiftUI
import UserNotifications

struct OverviewView: View {
    let state: AppState
    let showDetails: () -> Void
    let showSettings: () -> Void
    let showAlerts: () -> Void
    let edit: (ApplicationSnapshot) -> Void

    private var monitoring: MonitoringPresentation { MonitoringPresentation(state: state) }
    private var notificationTitle: String {
        guard state.notifications.available else { return "通知不可用" }
        switch state.notifications.status {
        case .authorized:
            return state.notifications.alerts == .disabled ? "通知提醒已关闭" : "通知已授权"
        case .denied: return "通知已拒绝"
        case .notDetermined: return "通知未授权"
        case .provisional: return "通知临时授权"
        case nil: return "通知状态待读取"
        @unknown default: return "通知状态未知"
        }
    }

    private var alertTitle: String {
        guard state.connected, state.snapshotIsCurrent else { return "预警状态未知" }
        let count = state.snapshot?.trafficAlertEvents.count ?? 0
        return count == 0 ? "暂无预警记录" : "预警记录 · \(count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            summary
            if monitoring.showsFailureReason, let message = state.snapshot?.message, !message.isEmpty {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let warning = state.trafficAlertWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            ApplicationListView(state: state, edit: edit)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label {
                    Text(monitoring.title).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: monitoring.symbol).foregroundStyle(monitoring.statusColor)
                }
                .font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                SamplingControl(state: state)
            }
            HStack {
                Label(state.networkName, systemImage: "network").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if state.showsHotspotControl {
                    Toggle(isOn: Binding(
                        get: { state.hotspotMarked },
                        set: { state.setHotspotOverride($0) }
                    )) { Text("手动热点") }
                    .toggleStyle(.switch).controlSize(.small).font(.caption).fixedSize()
                    .disabled(!state.canConfigureNetwork)
                    .help(state.canConfigureNetwork ? "手动标记当前连接，计入同一每日预算" : state.networkUnavailableReason)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("今日接口用量").font(.caption).foregroundStyle(.secondary)
                    Text(UsageFormatter.bytes(state.totalUsage))
                        .font(.system(.largeTitle, design: .rounded).weight(.semibold)).monospacedDigit()
                        .accessibilityLabel("今日接口上传与下载总量：\(UsageFormatter.bytes(state.totalUsage))")
                }
                Spacer()
                Button("用量详情", action: showDetails).font(.caption).buttonStyle(.plain)
            }
            Text(state.interfaceSummary).font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button(action: showSettings) {
                    Label(notificationTitle, systemImage: "bell")
                }
                .foregroundStyle(state.notifications.status == .authorized ? Color.secondary : .orange)
                Spacer()
                Button(action: showAlerts) {
                    Label(alertTitle, systemImage: "exclamationmark.bubble")
                }
                .foregroundStyle(.secondary)
                .help("查看已加载的当天预警；暂停与间断期间未知，可进入后加载全部记录")
            }
            .buttonStyle(.plain).font(.caption)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}
