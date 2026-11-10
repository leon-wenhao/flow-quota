import SwiftUI

struct PreferencesWindowView: View {
    let state: AppState
    let navigation: PreferencesNavigation
    @AppStorage("hasReadLocalSetup") private var hasReadLocalSetup = false

    var body: some View {
        HStack(spacing: 0) {
            PreferencesSidebar(navigation: navigation, version: state.updater.currentVersion)
            Divider()
            VStack(spacing: 0) {
                toolbar
                Divider()
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                ServiceFeedback(state: state).padding(.horizontal, 20).padding(.vertical, 8)
            }
        }
        .frame(minWidth: 820, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .appAppearance()
        .disclosureGroupStyle(FullRowDisclosureStyle())
        .onChange(of: state.selectedTrafficCategory) { _, _ in navigation.application = nil }
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            if navigation.page != .general && navigation.page != .help && navigation.page != .about {
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
                    .frame(maxWidth: navigation.page == .charts ? 1040 : 720, alignment: .leading)
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
        case .about: AboutView(state: state)
        case .help:
            SetupView(state: state) {
                hasReadLocalSetup = true
                navigation.select(.applications)
            }
        }
    }
}
