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
                Text("\(state.applications.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("按用量排序", systemImage: "arrow.down") { order.sortByUsage(state.applications) }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    .help("按当前用量重新排序；后台刷新保留应用位置")
            }
            .padding(.bottom, 6)
            Text("应用归因可能重叠，不相加作为接口总量。")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if state.applications.isEmpty {
                        ContentUnavailableView {
                            Label("暂无应用", systemImage: "app.dashed")
                        } description: {
                            Text("首次有效采样前，用量显示为未知。")
                        }
                    }
                    ForEach(order.ordered(state.applications)) { application in
                        ApplicationRow(application: application, usage: state.knownUsage(application)) {
                            edit(application)
                        }
                        Divider()
                    }
                }
            }
            .accessibilityLabel("应用用量列表")
        }
        .onAppear { order.reconcile(state.applications) }
        .onChange(of: state.applications.map(\.id)) { _, _ in order.reconcile(state.applications) }
        // Polling updates values without implicit row movement or transition animations.
        .transaction { $0.animation = nil }
    }
}
