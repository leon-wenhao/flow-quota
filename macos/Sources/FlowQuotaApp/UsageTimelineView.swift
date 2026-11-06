import FlowQuotaCore
import FlowQuotaPlatform
import SwiftUI

struct UsageTimelineView: View {
    let state: AppState
    @State private var range: TimeRange = .lastHour
    @State private var customStart = Calendar.current.startOfDay(for: Date())
    @State private var customEnd = Date()
    @State private var result: ApplicationUsageTimeline?
    @State private var loadError: String?
    @State private var initialDate = Date()

    private enum TimeRange: String, CaseIterable {
        case lastHour = "最近一小时", today = "今天", custom = "自定义"
    }
    private struct Refresh: Equatable {
        let query: ApplicationTimelineQuery?
        let snapshotDate: Date?
        let usable: Bool
    }

    private var snapshotUsable: Bool { state.connected && state.snapshotIsCurrent }

    var body: some View {
        let now = state.snapshot?.generatedAt ?? initialDate
        let dayStart = Calendar.current.startOfDay(for: Date())
        let query = query(now: now, dayStart: dayStart)
        let data = result.flatMap { $0.query == query ? ApplicationTimelinePresentation.make($0) : nil }
        let clash = result.flatMap { $0.query == query ? ApplicationTimelinePresentation.make($0, scope: .clash) : nil }
        let meter = query.flatMap { MacTrafficTimeline.make(query: $0, minutes: state.categorySnapshot?.interfaceUsageMinutes) }
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection(title: "Mac 分时总流量") {
                FlowQuotaSegmentedControl(
                    options: TimeRange.allCases,
                    selection: $range,
                    title: { $0.rawValue },
                    accessibilityLabel: "图表时间范围"
                )
                if range == .custom {
                    HStack {
                        DatePicker("从", selection: $customStart, in: dayStart...max(dayStart, now), displayedComponents: .hourAndMinute)
                        DatePicker("到", selection: $customEnd, in: dayStart...max(dayStart, now), displayedComponents: .hourAndMinute)
                    }
                    .font(.caption)
                }
                if let meter, snapshotUsable {
                    chart(meter, processes: data, clash: clash)
                } else {
                    message(!snapshotUsable ? "服务未连接或快照已过期，请刷新。" : query == nil
                        ? "请选择当天有效时段。" : "接口分时记录未知；不会用应用合计代替。")
                }
                if let loadError { Text("应用明细读取失败：\(loadError)；接口总量仍独立展示。").font(.caption).foregroundStyle(.orange) }
            }
            .zIndex(1)
            if snapshotUsable {
                TrafficSourceDetailsView(processes: data, clash: clash, total: meter?.summary)
                if let data, data.summary.totalBytes != nil { UsageChartsView(data: data) }
            }
        }
        .task(id: Refresh(query: query, snapshotDate: state.snapshot?.generatedAt, usable: snapshotUsable)) {
            guard let query, snapshotUsable else { return }
            do {
                let next = try await state.client.fetchApplicationTimeline(query)
                try Task.checkCancellation()
                guard next.query == query, ApplicationTimelinePresentation.make(next) != nil,
                      ApplicationTimelinePresentation.make(next, scope: .clash) != nil else {
                    throw PlatformError.malformedReply
                }
                result = next
                loadError = nil
            } catch is CancellationError {
                // Range/category changes invalidate the old reply without a layout reset.
            } catch {
                guard !Task.isCancelled else { return }
                loadError = error.localizedDescription
            }
        }
        .onChange(of: dayStart) {
            customStart = dayStart
            customEnd = max(dayStart, now)
        }
        .onChange(of: state.selectedTrafficCategory) { loadError = nil }
    }

    private func query(now: Date, dayStart: Date) -> ApplicationTimelineQuery? {
        guard now >= dayStart, let day = AppState.localDay() else { return nil }
        let upper = Date(timeIntervalSince1970: ceil(now.timeIntervalSince1970 / 60) * 60)
        let lower = range == .today ? dayStart : range == .lastHour ? max(dayStart, upper.addingTimeInterval(-3_600)) : customStart
        let end = range == .custom ? min(customEnd, now) : now
        guard lower < end else { return nil }
        return ApplicationTimelineQuery(day: day, category: state.selectedTrafficCategory,
            start: Date(timeIntervalSince1970: floor(lower.timeIntervalSince1970 / 60) * 60),
            end: Date(timeIntervalSince1970: ceil(end.timeIntervalSince1970 / 60) * 60), appKey: nil)
    }

    private func chart(_ data: ApplicationTimelinePresentation, processes: ApplicationTimelinePresentation?,
                       clash: ApplicationTimelinePresentation?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(UsageFormatter.bytes(data.summary.totalBytes)).font(.title2.bold()).monospacedDigit()
                    Text("Mac 接口上传＋下载合计").font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("所选时段 Mac 接口上传与下载总量")
                .accessibilityValue(UsageFormatter.bytes(data.summary.totalBytes))
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(time(data.summary.interval.start))–\(time(data.summary.interval.end)) · 每组 \(data.summary.bucketMinutes) 分钟")
                    Text("每组左侧上传、右侧下载")
                }
                .font(.caption).foregroundStyle(.secondary)
                Image(systemName: "info.circle")
                    .help("总量来自所选物理接口，包含全部有效观测字节，不因应用来源未知而减少。每组左侧上传、右侧下载；悬停查看总量及进程线索，完整明细在下方。进程及 Clash 辅助来源可能重叠，不相加作为接口总量；无法对应的差额会明确显示。空白未观测，圆点为观测零；采样间断不补量。")
                    .accessibilityLabel("Mac 总流量统计说明")
            }
            if data.summary.totalBytes != nil {
                UsageTimelineChart(data: data, processes: processes, clash: clash, isInterface: true)
            } else {
                message("此时段无接口观测，总量未知；应用明细仍单独保留。")
            }
        }
    }

    private func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
    private func message(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .center)
    }
}
