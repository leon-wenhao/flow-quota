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
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection(title: "应用分时用量") {
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
                if let data, snapshotUsable {
                    chart(data)
                } else {
                    message(!snapshotUsable ? "服务未连接或快照已过期，请刷新。" : query == nil
                        ? "请选择当天有效时段。" : loadError ?? "正在读取应用分时用量…")
                }
                if data != nil, let loadError { Text("更新失败：\(loadError)").font(.caption).foregroundStyle(.orange) }
            }
            .zIndex(1)
            if let data, data.summary.totalBytes != nil, snapshotUsable { UsageChartsView(data: data) }
        }
        .task(id: Refresh(query: query, snapshotDate: state.snapshot?.generatedAt, usable: snapshotUsable)) {
            guard let query, snapshotUsable else { return }
            do {
                let next = try await state.client.fetchApplicationTimeline(query)
                try Task.checkCancellation()
                guard next.query == query, ApplicationTimelinePresentation.make(next) != nil else {
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

    private func chart(_ data: ApplicationTimelinePresentation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(UsageFormatter.bytes(data.summary.totalBytes)).font(.title2.bold()).monospacedDigit()
                    Text("上传＋下载合计").font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("所选时段应用上传与下载合计")
                .accessibilityValue(UsageFormatter.bytes(data.summary.totalBytes))
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(time(data.summary.interval.start))–\(time(data.summary.interval.end)) · 每组 \(data.summary.bucketMinutes) 分钟")
                    Text("每组左侧上传、右侧下载")
                }
                .font(.caption).foregroundStyle(.secondary)
                Image(systemName: "info.circle")
                    .help("大号数值是所选时段内上传与下载的应用用量合计。每组有两根柱子，左侧上传、右侧下载，不同颜色表示不同应用；悬停查看各应用用量。仅含升级后已观测的当天应用归因，可能重叠或不完整；空白未知，圆点为观测零。不等同接口总量，Clash 来源见应用列表。按所选范围展示归因选择前十来源，其余合并为其他应用。与应用列表一致隐藏代理内核；Clash 来源与普通应用可能重叠，合计不是接口总量，也不能视为直连量。" + (data.clashNotice ?? ""))
                    .accessibilityLabel("应用流量统计说明")
            }
            if data.summary.totalBytes != nil {
                UsageTimelineChart(data: data)
            } else {
                message("此时段暂无应用分时记录，升级前和暂停期间不补算。")
            }
        }
    }

    private func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
    private func message(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .center)
    }
}
