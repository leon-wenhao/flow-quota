import AppKit
import FlowQuotaCore
import SwiftUI

struct PanelView: View {
    let state: AppState
    @AppStorage("hasReadLocalSetup") private var hasReadLocalSetup = false
    @State private var page: Page = .overview
    @State private var selected: ApplicationSnapshot?

    init(state: AppState, showSettings: Bool = false) {
        self.state = state
        _page = State(initialValue: showSettings ? .settings : .overview)
    }

    private enum Page { case overview, setup, settings, editor, details, alerts }
    private var width: CGFloat { min(420, (NSScreen.main?.visibleFrame.width ?? 444) - 24) }
    private var height: CGFloat { min(680, (NSScreen.main?.visibleFrame.height ?? 760) - 80) }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(16)
            Divider()
            if page == .overview {
                OverviewView(state: state, showDetails: { page = .details }, showSettings: { page = .settings },
                             showAlerts: { page = .alerts }) { application in
                    selected = application
                    page = .editor
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        pageContent
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
            }
            Divider()
            footer.padding(12)
        }
        .frame(width: width, height: height)
        .background(.regularMaterial)
        .disclosureGroupStyle(FullRowDisclosureStyle())
        .onAppear { if !hasReadLocalSetup && page != .settings { page = .setup } }
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .setup:
            SetupView(state: state) { hasReadLocalSetup = true; page = .overview }
        case .settings: SettingsView(state: state)
        case .details: UsageDetailsView(state: state)
        case .alerts: TrafficAlertHistoryView(state: state)
        case .editor:
            if let selected {
                QuotaEditor(application: selected, state: state) { page = .overview }.id(selected.id)
            }
        case .overview: EmptyView()
        }
    }

    private var header: some View {
        HStack {
            if page != .overview {
                Button { page = .overview } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).accessibilityLabel("返回用量面板")
            }
            HStack(spacing: 6) {
                FlowQuotaAppIcon().frame(width: 30, height: 30)
                Text("Flow Quota").font(.headline)
            }
            Spacer()
            Button { state.refreshOnce() } label: {
                ZStack {
                    if state.refreshing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain).disabled(state.busy || state.refreshing)
            .accessibilityLabel(state.refreshing ? "正在刷新服务状态" : "刷新服务状态")
            .help("刷新服务状态")
            Button { page = .settings } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain).accessibilityLabel("设置")
        }
    }

    private var footer: some View {
        HStack {
            ServiceFeedback(state: state)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("使用说明") { page = .setup }.buttonStyle(.plain).font(.caption).fixedSize()
            Button("退出并停止采集") { state.requestQuit() }.font(.caption).fixedSize().disabled(state.busy)
        }
        // Status changes replace text inside this slot; they never resize the scroll viewport.
        .frame(height: 24)
    }
}
