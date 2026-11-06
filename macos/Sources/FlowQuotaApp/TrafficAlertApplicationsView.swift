import FlowQuotaCore
import SwiftUI

/// Full evidence is loaded only while this row is expanded. A failure remains
/// visible with retry; current usage is never substituted for missing evidence.
struct TrafficAlertApplicationsView: View {
    let event: TrafficAlertEvent
    let loadDetails: TrafficAlertDetailsLoader?
    @State private var applications: TrafficAlertApplications?
    @State private var failure: String?
    @State private var attempt = 0
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(event.kind == .dailyInterface ? "触发时的当日应用用量" : "预警时段应用用量")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            if let applications = applications ?? event.applications {
                evidence(applications)
            } else if let failure {
                HStack(alignment: .top) {
                    Text("应用明细读取失败：\(failure)").foregroundStyle(.orange)
                    Spacer(minLength: 8)
                    Button("重试") { attempt += 1 }.flowQuotaTextAction()
                }
            } else if event.applicationSummary == nil {
                Text("未记录应用明细").foregroundStyle(.secondary)
            } else if loading {
                ProgressView("正在读取应用明细…").controlSize(.small)
            }
        }
        .task(id: attempt) { await load() }
    }

    @ViewBuilder private func evidence(_ snapshot: TrafficAlertApplications) -> some View {
        if snapshot.items.isEmpty {
            Text(snapshot.observedAt == nil ? "应用明细暂不可用" : "未观测到应用正用量")
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 10) {
                Text("应用／系统服务").frame(maxWidth: .infinity, alignment: .leading)
                column("上传", width: 66)
                column("下载", width: 66)
                column("合计", width: 72)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if snapshot.displaySources.count > 8 {
                ScrollView { rows(snapshot.displaySources) }.frame(height: 248)
            } else { rows(snapshot.displaySources) }
        }
        if let observedAt = snapshot.observedAt {
            Text("\(event.kind == .dailyInterface ? "快照时间" : "应用观测时间")：\(observedAt.formatted(date: .omitted, time: .standard))")
                .foregroundStyle(.secondary)
        }
        if snapshot.omittedCount > 0 {
            Text("仅保留用量最高的 128 项，另有 \(snapshot.omittedCount) 项未保存。")
                .foregroundStyle(.orange)
        }
        if let notice = snapshot.notice { Text(notice).foregroundStyle(.secondary) }

    }

    private func rows(_ items: [ClashUsageSource]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(items) { item in
                HStack(alignment: .center, spacing: 10) {
                    Text(item.name).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(item.id)
                    column(UsageFormatter.bytes(item.uploadedBytes), width: 66)
                    column(UsageFormatter.bytes(item.downloadedBytes), width: 66)
                    column(UsageFormatter.bytes(item.uploadedBytes + item.downloadedBytes), width: 72)
                }
                .font(.caption).foregroundStyle(.primary).padding(.vertical, 7)
                if item.id != items.last?.id { Divider() }
            }
        }
    }

    private func column(_ text: String, width: CGFloat) -> some View {
        Text(text).monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
            .frame(width: width, alignment: .trailing)
    }

    @MainActor private func load() async {
        guard applications == nil, event.applications == nil, event.applicationSummary != nil else { return }
        loading = true
        failure = nil
        defer { loading = false }
        do {
            guard let loadDetails else { throw TrafficAlertError.invalidEvent }
            let detail = try await loadDetails(event)
            try Task.checkCancellation()
            applications = detail.applications
            if applications == nil { failure = "此记录缺少已保存的应用证据。" }
        } catch is CancellationError {
            // Closing the row or changing category cancels its read.
        } catch { failure = error.localizedDescription }
    }
}
