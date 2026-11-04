import AppKit
import FlowQuotaCore
import SwiftUI

struct PanelView: View {
    let state: AppState
    @AppStorage("hasReadLocalSetup") private var hasReadLocalSetup = false
    @State private var page: Page = .overview
    @State private var selected: ApplicationSnapshot?
    @State private var active = false

    init(state: AppState, showSettings: Bool = false) {
        self.state = state
        _page = State(initialValue: showSettings ? .settings : .overview)
    }

    private enum Page { case overview, setup, settings, editor }
    private var width: CGFloat { min(420, (NSScreen.main?.visibleFrame.width ?? 444) - 24) }
    private var height: CGFloat { min(680, (NSScreen.main?.visibleFrame.height ?? 760) - 80) }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ServiceFeedback(state: state)
                    switch page {
                    case .overview: overview
                    case .setup: SetupView(state: state) {
                        hasReadLocalSetup = true
                        page = .overview
                    }
                    case .settings: SettingsView(state: state)
                    case .editor:
                        if let selected {
                            QuotaEditor(application: selected, state: state) { page = .overview }
                                .id(selected.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            Divider()
            footer.padding(12)
        }
        .frame(width: width, height: height)
        .background(.regularMaterial)
        .background(PanelActivityReader { active = $0 })
        .task(id: active) {
            if active {
                await state.notifications.refresh()
                await state.pollWhileVisible()
            }
        }
        .onAppear { if !hasReadLocalSetup && page != .settings { page = .setup } }
        .onDisappear { active = false }
    }

    private var header: some View {
        HStack {
            if page != .overview {
                Button { page = .overview } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).accessibilityLabel("返回用量面板")
            }
            Label("Flow Quota", systemImage: "shield").font(.headline)
            Spacer()
            if state.refreshing { ProgressView().controlSize(.small).accessibilityLabel("正在刷新服务状态") }
            Button { page = .settings } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain).accessibilityLabel("设置")
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProtectionBanner(state: state)
            VStack(alignment: .leading, spacing: 8) {
                Label(networkTitle, systemImage: "network").font(.subheadline.bold())
                Text(networkDetail).font(.caption).foregroundStyle(.secondary)
                Button(state.hotspotMarked ? "取消手动热点标记" : "将当前连接标记为热点") {
                    state.setHotspotOverride(!state.hotspotMarked)
                }
                .disabled(!state.canConfigureNetwork)
                if !state.canConfigureNetwork { Text(state.networkUnavailableReason).font(.caption).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("今日热点用量").font(.subheadline).foregroundStyle(.secondary)
                Text(UsageFormatter.bytes(state.totalUsage)).font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .monospacedDigit().accessibilityLabel("今日热点用量：\(UsageFormatter.bytes(state.totalUsage))")
                Text("已归因应用的上传＋下载；未知或未计量的流量不显示为零。")
                    .font(.caption).foregroundStyle(.secondary)
                if let date = state.snapshot?.generatedAt {
                    Text("服务快照：\(date.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Text("应用与后台进程").font(.headline)
                Spacer()
                Text("按今日用量").font(.caption).foregroundStyle(.secondary)
            }
            if state.applications.isEmpty {
                ContentUnavailableView {
                    Label(state.usageAvailable ? "暂无已归因应用" : "尚未获取可计量的应用", systemImage: "app.dashed")
                } description: {
                    Text("此处只展示本地服务返回的应用。保护未就绪时不会生成示例用量。")
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(state.applications) { application in
                        ApplicationRow(application: application, usage: state.knownUsage(application)) {
                            selected = application
                            page = .editor
                        }
                        Divider()
                    }
                }
            }
        }
    }

    private var networkTitle: String {
        guard state.connected, state.snapshotIsCurrent else { return "当前连接：未知" }
        if state.hotspotMarked { return "当前连接：手动标记为热点" }
        switch state.snapshot?.network {
        case .hotspot: return "当前连接：手动标记为热点"
        case .ordinary: return "当前连接：普通网络"
        case .unknown, nil: return "当前连接：未知" }
    }
    private var networkDetail: String {
        state.hotspotMarked
            ? "服务已确认此标记；它不代表保护扩展已经启用。"
            : "高成本路径（isExpensive）只是热点候选信号，不能确认设备或运营商。"
    }
    private var footer: some View {
        HStack {
            Label("仅保存在本机", systemImage: "internaldrive").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("使用说明") { page = .setup }.buttonStyle(.plain).font(.caption)
            Button("退出并停止保护") { state.requestQuit() }
                .font(.caption).disabled(state.busy)
        }
    }
}
