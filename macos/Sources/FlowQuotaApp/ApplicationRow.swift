import FlowQuotaCore
import SwiftUI

struct ApplicationRow: View {
    let application: ApplicationSnapshot
    let usage: Int64?
    var compact = false
    let edit: () -> Void

    private var source: SystemProcessClassification { SystemProcessClassification(identity: application.identity) }
    private var status: String {
        switch source.category {
        case .sharedDownload, .sharedProxy: return "共享服务 · 原始请求方未确认"
        default: break
        }
        guard let usage else { return "用量未知" }
        guard let rule = application.rule, let limit = rule.limitBytes else { return "未设每日提醒" }
        if usage >= limit { return "已达提醒阈值" }
        if Double(usage) / Double(limit) >= Double(rule.warningPercent) / 100 { return "接近提醒阈值" }
        return "未达提醒阈值"
    }
    private var symbol: String {
        guard let usage, let rule = application.rule, let limit = rule.limitBytes else { return "app" }
        if usage >= limit { return "exclamationmark.octagon" }
        if Double(usage) / Double(limit) >= Double(rule.warningPercent) / 100 { return "exclamationmark.triangle" }
        return "app"
    }

    var body: some View {
        Button(action: edit) {
            TrafficSourceRowContent(name: source.displayName, symbol: symbol,
                status: status, usage: UsageFormatter.bytes(usage),
                scope: application.rule?.limitBytes.map { "阈值 \(UsageFormatter.bytes($0))" } ?? "每日归因", compact: compact)
        }
        .buttonStyle(FlowQuotaRowButtonStyle())
        .help("\(source.displayName)\n\(source.detail)")
        .accessibilityElement(children: .combine)
        .accessibilityHint("查看应用详情并编辑每日提醒阈值")
    }
}
