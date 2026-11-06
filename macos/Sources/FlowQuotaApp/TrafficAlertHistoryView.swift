import FlowQuotaCore
import SwiftUI

struct TrafficAlertHistoryView: View {
    let state: AppState
    @State private var showAll = false
    @State private var loaded: [TrafficAlertEvent] = []
    @State private var loading = false
    @State private var loadedDay: String?

    private var events: [TrafficAlertEvent] {
        let currentDay = AppState.localDay()
        let source = showAll && loadedDay == currentDay ? loaded : state.categoryEvents
        return showAll ? source : Array(source.prefix(10))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !state.connected || !state.snapshotIsCurrent {
                unavailableState
            } else {
                Text(state.categoryAlertMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                alertTable
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("预警记录").flowQuotaPageTitle()
            Spacer()
            if showAll {
                Button("收起记录") { showAll = false }
                    .settingsAction()
            }
            Button(showAll ? "刷新记录" : "全部记录", systemImage: "arrow.clockwise") {
                loadAll()
            }
            .settingsAction()
            .disabled(loading || !state.connected || !state.snapshotIsCurrent)
            .accessibilityLabel(showAll ? "刷新当天全部记录" : "加载当天全部记录")
            .overlay(alignment: .leading) {
                if loading {
                    ProgressView()
                        .controlSize(.small)
                        .offset(x: -24)
                }
            }
        }
    }

    private var unavailableState: some View {
        Text("服务未连接或快照过期；预警记录暂不可确认。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 22)
            .background(FlowQuotaTheme.cardFill.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private var alertTable: some View {
        VStack(spacing: 0) {
            TrafficAlertTableHeader()
            if events.isEmpty {
                TrafficAlertEmptyRow()
            } else {
                ForEach(events) { event in
                    TrafficAlertTableRow(event: event)
                    if event.id != events.last?.id {
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
        .background(FlowQuotaTheme.cardFill.opacity(0.42), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(FlowQuotaTheme.border, lineWidth: 0.8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("当天预警记录表")
    }

    private func loadAll() {
        guard !loading else { return }
        loading = true
        state.clearMessages()
        Task { @MainActor in
            defer { loading = false }
            do {
                loaded = try await state.loadTodayTrafficAlerts()
                loadedDay = AppState.localDay()
                showAll = true
            } catch {
                state.reportError("无法读取当天记录：\(error.localizedDescription)")
            }
        }
    }
}

private struct TrafficAlertTableHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("时间").frame(width: 70, alignment: .leading)
            Text("预警类型").frame(width: 150, alignment: .leading)
            Text("来源").frame(maxWidth: .infinity, alignment: .leading)
            Text("用量").frame(width: 116, alignment: .trailing)
            Text("通知").frame(width: 92, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(FlowQuotaTheme.inputFill.opacity(0.55))
    }
}

private struct TrafficAlertEmptyRow: View {
    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: "checkmark.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("今天暂无预警记录")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text("达到配置的提醒阈值后，记录会显示在这里。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 132)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }
}

private struct TrafficAlertTableRow: View {
    let event: TrafficAlertEvent
    @State private var detailsExpanded = false

    private var source: SystemProcessClassification {
        SystemProcessClassification(identity: AppIdentity(key: event.sourceKey, name: event.sourceName))
    }

    private var sourceTitle: String {
        event.kind == .applicationBurst ? source.displayName : "本机计量接口"
    }

    private var typeTitle: String {
        "\(event.category.title) · \(event.kind.title)"
    }

    private var notificationTitle: String {
        event.scheduledAt == nil ? "未提交" : "已提交"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text(event.occurredAt.formatted(date: .omitted, time: .standard))
                    .frame(width: 70, alignment: .leading)
                Text(typeTitle)
                    .frame(width: 150, alignment: .leading)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text(sourceTitle)
                    if event.kind == .applicationBurst && !event.sourceName.isEmpty {
                        Text("应用")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(UsageFormatter.bytes(event.observedBytes))
                    Text("阈值 \(UsageFormatter.bytes(event.thresholdBytes))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 116, alignment: .trailing)
                Text(notificationTitle)
                    .frame(width: 92, alignment: .leading)
                    .foregroundStyle(event.scheduledAt == nil ? .orange : .secondary)
            }
            .font(.caption)
            .monospacedDigit()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            DisclosureGroup(isExpanded: $detailsExpanded) {
                TrafficAlertDetails(event: event, source: source)
                    .padding(.top, 7)
            } label: {
                Label("计量与来源说明", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, detailsExpanded ? 10 : 8)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }
}

private struct TrafficAlertDetails: View {
    let event: TrafficAlertEvent
    let source: SystemProcessClassification

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(event.kind == .applicationBurst ? source.detail
                : "物理接口独立计量；包含局域网和协议开销，不能据此认定为壁纸下载或运营商扣费。")
            if !event.sourceKey.isEmpty {
                Text("来源名称：\(event.sourceName)")
                Text("来源标识：\(event.sourceKey)")
                    .textSelection(.enabled)
            }
            if event.kind != .dailyInterface {
                Text("连续观测：\(event.observedSeconds) 秒；窗口上限：\(event.windowSeconds / 60) 分钟")
            }
            Text("预警配置版本：\(event.policyVersion)")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
}
