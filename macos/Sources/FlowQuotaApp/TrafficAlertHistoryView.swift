import FlowQuotaCore
import SwiftUI

struct TrafficAlertHistoryView: View {
    let state: AppState
    @State private var showAll = false
    @State private var loaded: [TrafficAlertEvent] = []
    @State private var loading = false
    @State private var loadedDay: String?
    @State private var showsStatus = false

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
                if let warning = state.trafficAlertWarning {
                    Label { Text(warning).textSelection(.enabled) } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                TrafficAlertHistoryTable(events: events, loadDetails: { try await state.loadTrafficAlertDetails($0) })
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("预警记录").flowQuotaPageTitle()
            Spacer()
            Button("状态与说明", systemImage: "info.circle") { showsStatus = true }
                .settingsAction()
                .popover(isPresented: $showsStatus) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("预警状态").font(.headline)
                        Text(state.connected && state.snapshotIsCurrent ? state.categoryAlertMessage
                             : "服务未连接或快照过期，当前预警状态无法确认。")
                            .font(.caption).textSelection(.enabled)
                        Text("这里显示当前预警运行状态；下方表格保存今天已触发的记录。点击整条记录可查看完整来源和计量详情。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(16).frame(width: 320, alignment: .leading)
                }
            if showAll {
                Button("收起记录") { showAll = false }
                    .settingsAction()
            }
            Button(showAll ? "刷新记录" : "查看全部", systemImage: showAll ? "arrow.clockwise" : "list.bullet") {
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
