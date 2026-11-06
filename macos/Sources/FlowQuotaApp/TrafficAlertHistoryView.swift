import FlowQuotaCore
import SwiftUI

struct TrafficAlertHistoryView: View {
    let state: AppState
    @State private var showAll = false
    @State private var loaded: [TrafficAlertEvent] = []
    @State private var loading = false
    @State private var loadedDay: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text("预警记录").flowQuotaPageTitle()
                Spacer()
                if showAll {
                    Button("收起记录") { showAll = false }.settingsAction()
                }
                Button(showAll ? "刷新记录" : "全部记录", systemImage: "arrow.clockwise") { loadAll() }
                    .settingsAction().disabled(loading || !state.connected || !state.snapshotIsCurrent)
                    .accessibilityLabel(showAll ? "刷新当天全部记录" : "加载当天全部记录")
                    .overlay(alignment: .leading) {
                        if loading { ProgressView().controlSize(.small).offset(x: -24) }
                    }
            }
            if !state.connected || !state.snapshotIsCurrent {
                Text("服务未连接或快照过期；预警记录暂不可确认。").font(.caption)
            } else {
                Text(state.categoryAlertMessage)
                    .font(.caption).foregroundStyle(.secondary)
                let events = showAll && loadedDay == AppState.localDay() ? loaded : state.categoryEvents
                if events.isEmpty {
                    Text("今天暂无预警记录。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(showAll ? events : Array(events.prefix(10))) { event in
                        TrafficAlertEventRow(event: event)
                        Divider()
                    }
                }
            }
        }
    }

    private func loadAll() {
        guard !loading else { return }
        loading = true; state.clearMessages()
        Task { @MainActor in
            defer { loading = false }
            do {
                loaded = try await state.loadTodayTrafficAlerts()
                loadedDay = AppState.localDay(); showAll = true
            } catch { state.reportError("无法读取当天记录：\(error.localizedDescription)") }
        }
    }
}

private struct TrafficAlertEventRow: View {
    let event: TrafficAlertEvent
    private var source: SystemProcessClassification {
        SystemProcessClassification(identity: AppIdentity(key: event.sourceKey, name: event.sourceName))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(event.category.title) · \(event.kind.title)").font(.subheadline.bold())
            Text(event.kind == .applicationBurst ? source.displayName : "本机计量接口 · 来源未确认")
                .font(.subheadline)
            Text("\(event.occurredAt.formatted(date: .omitted, time: .standard)) · 上传＋下载 \(UsageFormatter.bytes(event.observedBytes)) · 阈值 \(UsageFormatter.bytes(event.thresholdBytes))")
                .font(.caption).monospacedDigit()
            if event.kind != .dailyInterface {
                Text("最近最多 \(event.windowSeconds / 60) 分钟，实际连续观测 \(event.observedSeconds) 秒")
                    .font(.caption2)
            }
            Text(event.scheduledAt == nil ? "尚未确认提交系统通知" : "系统已接受通知请求；不保证横幅已展示")
                .font(.caption2).foregroundStyle(.secondary)
            DisclosureGroup("计量与来源说明") {
                Text(event.kind == .applicationBurst ? source.detail
                    : "物理接口独立计量；包含局域网和协议开销，不能据此认定为壁纸下载或运营商扣费。")
                    .font(.caption)
                if !event.sourceKey.isEmpty {
                    Text(event.sourceName).font(.caption)
                    Text(event.sourceKey).font(.caption2).textSelection(.enabled)
                }
                Text("预警配置版本 \(event.policyVersion)").font(.caption2)
            }
        }
    }
}
