import FlowQuotaCore
import SwiftUI

/// Four shared columns reserve readable space for the event and its source, even
/// at the preferences window's minimum width. Raw identity stays in the details.
private enum TrafficAlertTableLayout {
    static let time: CGFloat = 66
    static let amount: CGFloat = 96
    static let notification: CGFloat = 84
    static let spacing: CGFloat = 12
    static let padding: CGFloat = 14
}

struct TrafficAlertHistoryTable: View {
    let events: [TrafficAlertEvent]

    var body: some View {
        VStack(spacing: 0) {
            TrafficAlertTableHeader()
            if events.isEmpty {
                TrafficAlertEmptyRow()
            } else {
                ForEach(events) { event in
                    TrafficAlertTableRow(event: event)
                    if event.id != events.last?.id { Divider().padding(.horizontal, TrafficAlertTableLayout.padding) }
                }
            }
        }
        .background(FlowQuotaTheme.cardFill.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(FlowQuotaTheme.border, lineWidth: 0.8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("当天预警记录表")
    }
}

private struct TrafficAlertTableHeader: View {
    var body: some View {
        HStack(spacing: TrafficAlertTableLayout.spacing) {
            Text("时间").frame(width: TrafficAlertTableLayout.time, alignment: .leading)
            Text("预警内容").frame(maxWidth: .infinity, alignment: .leading)
            Text("用量 / 阈值").frame(width: TrafficAlertTableLayout.amount, alignment: .trailing)
            Text("通知状态").frame(width: TrafficAlertTableLayout.notification, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, TrafficAlertTableLayout.padding)
        .padding(.vertical, 12)
        .background(FlowQuotaTheme.inputFill.opacity(0.55))
    }
}

private struct TrafficAlertEmptyRow: View {
    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: "checkmark.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("今天暂无预警记录")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text("达到配置的提醒阈值后，记录会显示在这里。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 132)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }
}

private struct TrafficAlertTableRow: View {
    let event: TrafficAlertEvent
    @State private var detailsExpanded = false

    private var source: SystemProcessClassification {
        SystemProcessClassification(identity: AppIdentity(key: event.sourceKey, name: event.sourceName))
    }
    private var sourceTitle: String {
        event.kind == .applicationBurst ? source.displayName : "本机计量接口"
    }
    private var typeTitle: String {
        switch event.kind {
        case .dailyInterface: "每日总量预警"
        case .interfaceBurst: "短时流量预警"
        case .applicationBurst: "应用流量预警"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { detailsExpanded.toggle() } label: {
                HStack(alignment: .center, spacing: TrafficAlertTableLayout.spacing) {
                    Text(event.occurredAt.formatted(date: .omitted, time: .standard))
                        .font(.caption).monospacedDigit()
                        .frame(width: TrafficAlertTableLayout.time, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(typeTitle).font(.subheadline.weight(.semibold))
                        Text(sourceTitle).font(.caption).foregroundStyle(.secondary)
                            .truncationMode(.middle)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(sourceTitle)
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(UsageFormatter.bytes(event.observedBytes)).font(.subheadline.weight(.medium))
                        Text("阈值 \(UsageFormatter.bytes(event.thresholdBytes))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .monospacedDigit().lineLimit(1)
                    .frame(width: TrafficAlertTableLayout.amount, alignment: .trailing)
                    HStack(spacing: 6) {
                        Text(event.scheduledAt == nil ? "未提交" : "已提交")
                            .foregroundStyle(event.scheduledAt == nil ? Color.orange : Color.secondary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(detailsExpanded ? 90 : 0))
                            .foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                    .font(.caption).lineLimit(1)
                    .frame(width: TrafficAlertTableLayout.notification, alignment: .leading)
                    .help(event.scheduledAt == nil ? "尚未向系统成功提交通知，请查看通知权限和操作反馈。"
                          : "系统已接受通知请求，不代表已显示横幅或用户已阅读。")
                }
                .padding(.horizontal, TrafficAlertTableLayout.padding)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(FlowQuotaRowButtonStyle())
            .accessibilityValue(detailsExpanded ? "已展开" : "已收起")
            .accessibilityHint(detailsExpanded ? "收起记录详情" : "展开记录详情")
            if detailsExpanded {
                Divider().padding(.horizontal, TrafficAlertTableLayout.padding)
                TrafficAlertDetails(event: event, source: source)
                    .padding(TrafficAlertTableLayout.padding)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct TrafficAlertDetails: View {
    let event: TrafficAlertEvent
    let source: SystemProcessClassification

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("预警类型：\(event.kind.title)")
            Text("网络类别：\(event.category.title)")
            Text(event.kind == .applicationBurst ? source.detail
                : "物理接口独立计量；包含局域网和协议开销，不能据此认定为壁纸下载或运营商扣费。")
            if !event.sourceKey.isEmpty {
                Text("来源名称：\(event.sourceName)")
                Text("来源标识：\(event.sourceKey)")
            }
            if event.kind != .dailyInterface {
                Text("连续观测：\(event.observedSeconds) 秒；窗口上限：\(event.windowSeconds / 60) 分钟")
            }
            Text("预警配置版本：\(event.policyVersion)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
}
