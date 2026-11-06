import FlowQuotaCore
import SwiftUI

/// Raw observations and reconciliation belong here, outside the daily source list.
struct TrafficMeasurementDetailsView: View {
    let state: AppState
    let edit: (ApplicationSnapshot) -> Void

    var body: some View {
        SettingsSection(title: "计量原始记录") {
            ForEach(UsageDirection.allCases) { direction in
                Text(direction.rawValue + "计数核对").font(.subheadline)
                TrafficMeasurementStatus(total: state.totalUsage.flatMap { _ in state.categoryInterfaceUsage }.map {
                    direction.bytes(upload: $0.uploadedBytes, download: $0.downloadedBytes)
                }, processes: state.usageAvailable ? UsageFormatter.total(state.applications.map {
                    direction.bytes(upload: $0.usage.uploadedBytes, download: $0.usage.downloadedBytes)
                }) : nil)
            }
            ForEach(state.applications.filter { ClashUsageBreakdown.isProxy($0.identity) }) { app in
                ApplicationRow(application: app, usage: state.knownUsage(app)) { edit(app) }
            }
            if let notice = state.categorySnapshot?.clashBreakdown?.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            if let failure = state.clashSourceFailure { Text(failure).font(.caption).foregroundStyle(.orange) }
            if let observations = state.categorySnapshot?.clashSourceObservations, !observations.isEmpty {
                DisclosureGroup("Clash API 当天原始来源计数") {
                    ForEach(observations) { source in
                        HStack {
                            Text(source.name)
                            Spacer()
                            Text(UsageFormatter.bytes(source.uploadedBytes + source.downloadedBytes)).monospacedDigit()
                        }.font(.caption)
                    }
                    Text("原始 API 观测可能与内核时段计数不一致；日常列表仅使用可核对部分，余量完整保留为其他未识别。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
