import SwiftUI

struct PreferencesWindowView: View {
    let state: AppState
    let navigation: PreferencesNavigation
    @AppStorage("hasReadLocalSetup") private var hasReadLocalSetup = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                toolbar
                Divider()
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                ServiceFeedback(state: state).padding(.horizontal, 20).padding(.vertical, 8)
            }
        }
        .frame(minWidth: 740, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .appAppearance()
        .disclosureGroupStyle(FullRowDisclosureStyle())
        .onChange(of: state.selectedTrafficCategory) { _, _ in navigation.application = nil }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                FlowQuotaAppIcon().frame(width: 28, height: 28)
                Text("Flow Quota").font(.headline)
            }
            .padding(.bottom, 18).padding(.horizontal, 8)
            ForEach(PreferencesNavigation.Page.allCases) { page in
                Button { navigation.select(page) } label: {
                    Label(page.title, systemImage: page.symbol)
                        .font(.subheadline.weight(navigation.page == page ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 11).padding(.vertical, 10)
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(FlowQuotaRowButtonStyle())
                .background(navigation.page == page ? FlowQuotaTheme.accent.opacity(0.13) : .clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .leading) {
                    if navigation.page == page {
                        Capsule().fill(FlowQuotaTheme.accent).frame(width: 3, height: 20).padding(.leading, 2)
                    }
                }
                .accessibilityAddTraits(navigation.page == page ? .isSelected : [])
            }
            Spacer()
            Text("用量与配置仅保存在本机")
                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 8)
        }
        .padding(14).padding(.top, 14).frame(width: 184)
        .background(.regularMaterial)
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            if navigation.page != .general && navigation.page != .help {
                TrafficCategorySelection(state: state)
                    .frame(maxWidth: .infinity)
            } else {
                Text(navigation.page.title).font(.headline)
            }
            Spacer(minLength: 0)
            Button { state.refreshOnce() } label: {
                ZStack {
                    if state.refreshing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .frame(width: 20, height: 20)
            }
            .buttonStyle(FlowQuotaIconButtonStyle()).disabled(state.busy || state.refreshing)
            .accessibilityLabel("刷新服务状态").help("刷新服务状态")
        }
        .padding(.horizontal, 22).frame(height: 58)
    }

    @ViewBuilder private var content: some View {
        if navigation.page == .applications && navigation.application == nil {
            ApplicationListView(state: state) { navigation.application = $0 }
                .id(state.selectedTrafficCategory).padding(20)
        } else {
            GeometryReader { viewport in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        pageContent
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(20).frame(maxWidth: .infinity, alignment: .top)
                }
                .environment(\.chartTooltipViewport, viewport.frame(in: .global))
                .id(navigation.page)
            }
        }
    }

    @ViewBuilder private var pageContent: some View {
        switch navigation.page {
        case .applications:
            if let application = navigation.application {
                Button("返回应用列表", systemImage: "chevron.left") { navigation.application = nil }
                    .flowQuotaTextAction()
                QuotaEditor(application: application, state: state) { navigation.application = nil }
                    .id("\(state.selectedTrafficCategory.rawValue):\(application.id)")
            }
        case .charts: UsageDashboardView(state: state).id(state.selectedTrafficCategory)
        case .details:
            UsageDetailsView(state: state, showCharts: { navigation.select(.charts) })
            TrafficMeasurementDetailsView(state: state) { app in
                navigation.select(.applications)
                navigation.application = app
            }
            if let proxy = state.categoryMihomoProxy { MihomoProxyCard(proxy: proxy) }
        case .reminders: ReminderSettingsView(state: state).id(state.selectedTrafficCategory)
        case .history: TrafficAlertHistoryView(state: state).id(state.selectedTrafficCategory)
        case .general: SettingsView(state: state)
        case .help:
            SetupView(state: state) {
                hasReadLocalSetup = true
                navigation.select(.applications)
            }
        }
    }
}
