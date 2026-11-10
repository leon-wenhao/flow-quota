import FlowQuotaCore
import SwiftUI

/// Compact presentation of the shared ranking. A reserved three-row area keeps
/// polling and category switches from resizing the menu panel under the pointer.
struct TopUsageListView: View {
    let state: AppState
    let openApplication: (ApplicationSnapshot) -> Void

    private var items: [ApplicationUsageItem] { state.topUsageItems }
    private var emptyMessage: String {
        guard state.connected, state.snapshotIsCurrent else { return "用量暂不可用，等待服务更新。" }
        if state.applicationUsageItems.contains(where: { $0.bytes != nil }) { return "暂未产生已观测用量。" }
        return "等待有效用量记录。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("用量前三").font(.caption.weight(.semibold))
                Spacer()
                Text("接口总量内的已核对来源").font(.caption2).foregroundStyle(.secondary)
            }
            if items.isEmpty {
                Text(emptyMessage).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 6) {
                            Text("\(index + 1)").font(.caption2).monospacedDigit()
                                .foregroundStyle(.secondary).frame(width: 12)
                                .accessibilityLabel("第 \(index + 1) 名")
                            switch item {
                            case .application(let application, let bytes):
                                ApplicationRow(application: application, usage: bytes, thresholdUsage: state.knownUsage(application), compact: true) {
                                    openApplication(application)
                                }
                            case .clash(let source, let bytes):
                                ClashSourceRow(source: source, usage: bytes,
                                    status: state.categoryMihomoProxy?.status ?? .unavailable, compact: true)
                            case .unidentified(let source):
                                UnidentifiedTrafficRow(source: source, compact: true)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Text(state.trafficBreakdownError == nil ? "未识别余量与原始证据见计量详情" : "来源核对失败 · 详情见计量详情")
                .font(.caption2).foregroundStyle(
                    state.trafficBreakdownError == nil ? Color.secondary : Color.orange
                )
        }
        .frame(height: 148, alignment: .top)
        .transaction { $0.animation = nil }
    }
}
