import FlowQuotaCore
import SwiftUI
import UserNotifications

struct OverviewView: View {
    let state: AppState
    let openPreferences: (PreferencesNavigation.Page) -> Void
    var openApplication: ((ApplicationSnapshot) -> Void)? = nil
    private var monitoring: MonitoringPresentation { MonitoringPresentation(state: state) }

    private var notificationTitle: String {
        guard state.notifications.available else { return "通知不可用" }
        switch state.notifications.status {
        case .authorized: return state.notifications.alerts == .disabled ? "通知已关闭" : "通知已授权"
        case .denied: return "通知已拒绝"
        case .notDetermined: return "通知未授权"
        case .provisional: return "通知临时授权"
        case nil: return "通知待读取"
        @unknown default: return "通知状态未知"
        }
    }

    private var warning: String? {
        if monitoring.showsFailureReason, let message = state.snapshot?.message, !message.isEmpty { return message }
        return state.trafficAlertWarning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label {
                        Text(monitoring.title).foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: monitoring.symbol).foregroundStyle(monitoring.statusColor)
                    }
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    SamplingControl(state: state)
                }
                .frame(height: 24)
                HStack {
                    Label(state.networkName, systemImage: "network")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if state.showsHotspotControl {
                        Toggle(isOn: Binding(get: { state.hotspotMarked }, set: { state.setHotspotOverride($0) })) {
                            Text("手动热点")
                        }
                        .toggleStyle(FlowQuotaToggleStyle()).font(.caption).fixedSize()
                        .disabled(!state.canConfigureNetwork).help(state.networkDetail)
                    }
                }
                .frame(height: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text("今日接口用量 · \(state.selectedTrafficCategory.title)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(UsageFormatter.bytes(state.totalUsage))
                        .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                        .accessibilityLabel("今日接口上传与下载总量：\(UsageFormatter.bytes(state.totalUsage))")
                    Text(state.interfaceSummary).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).frame(height: 32, alignment: .topLeading).help(state.interfaceMenuHelp)
                }
                TopUsageListView(state: state) { application in
                    if let openApplication { openApplication(application) }
                    else { openPreferences(.applications) }
                }
                Divider()
                HStack {
                    Button { openPreferences(.reminders) } label: {
                        Label(notificationTitle, systemImage: "bell")
                    }
                    .foregroundStyle(state.notifications.status == .authorized ? Color.secondary : .orange)
                    Spacer()
                    Button { openPreferences(.history) } label: {
                        Label(state.connected && state.snapshotIsCurrent
                              ? "预警记录 · \(state.categoryEvents.count)" : "预警状态未知",
                              systemImage: "clock.arrow.circlepath")
                    }
                    .foregroundStyle(.secondary)
                    .help("查看当天预警记录")
                }
                .flowQuotaTextAction().controlSize(.small).font(.caption)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 12) {
                Button { openPreferences(.applications) } label: { Label("应用用量", systemImage: "square.grid.2x2") }
                Spacer()
                Button { openPreferences(.charts) } label: { Label("用量图表", systemImage: "chart.pie") }
            }
            .flowQuotaTextAction().controlSize(.small).font(.subheadline).padding(.horizontal, 4)
            // Reserve a compact warning slot so polling never resizes the menu surface.
            Button { openPreferences(monitoring.showsFailureReason ? .details : .reminders) } label: {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: warning == nil ? "info.circle" : "exclamationmark.triangle")
                    Text(warning ?? "仅统计已观测用量；达到阈值时提醒。")
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption2).foregroundStyle(warning == nil ? Color.secondary : .orange)
                .frame(height: 32, alignment: .topLeading).contentShape(Rectangle())
            }
            .flowQuotaTextAction().controlSize(.small).help(warning ?? "本机物理接口上传＋下载，不等于运营商账单。")
        }
    }
}
