import FlowQuotaCore
import SwiftUI

struct ApplicationListView: View {
    let state: AppState
    let edit: (ApplicationSnapshot) -> Void
    @State private var order = ApplicationListOrder()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("应用用量").font(.headline)
                Text("\(state.applicationUsageItems.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("按用量排序", systemImage: "arrow.down") { order.sortByUsage(state.applicationUsageItems) }
                    .flowQuotaTextAction().font(.caption).foregroundStyle(.secondary)
                    .help("按当前用量重新排序；后台刷新保留应用位置")
            }
            .padding(.bottom, 6)
            Text(state.clashAttributionNotice)
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
            DailyTrafficOverview(state: state)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if state.applicationUsageItems.isEmpty {
                        ContentUnavailableView {
                            Label("暂无应用", systemImage: "app.dashed")
                        } description: {
                            Text("首次有效采样前，用量显示为未知。")
                        }
                    }
                    ForEach(order.ordered(state.applicationUsageItems)) { item in
                        switch item {
                        case .application(let application, let usage):
                            ApplicationRow(application: application, usage: usage) { edit(application) }
                        case .clash(let source, let usage):
                            ClashSourceRow(source: source, usage: usage,
                                status: state.categoryMihomoProxy?.status ?? .unavailable)
                        }
                        Divider()
                    }
                    if !state.clashUsageItems.isEmpty {
                        DisclosureGroup("Clash 识别来源（辅助明细，不重复计入总量）") {
                            ForEach(state.clashUsageItems) { item in
                                if case .clash(let source, let usage) = item {
                                    ClashSourceRow(source: source, usage: usage,
                                        status: state.categoryMihomoProxy?.status ?? .unavailable)
                                }
                            }
                        }
                        .padding(.vertical, 10)
                    }
                }
            }
            .accessibilityLabel("应用用量列表")
        }
        .onAppear { order.reconcile(state.applicationUsageItems) }
        .onChange(of: state.applicationUsageItems.map(\.id)) { _, _ in order.reconcile(state.applicationUsageItems) }
        // Polling updates values without implicit row movement or transition animations.
        .transaction { $0.animation = nil }
    }
}
