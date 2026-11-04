import FlowQuotaCore
import SwiftUI

struct ApplicationRow: View {
    let application: ApplicationSnapshot
    let usage: Int64?
    let edit: () -> Void

    private var status: String {
        guard let usage else { return "用量未知 · 未确认计量状态" }
        guard let rule = application.rule, let limit = rule.limitBytes else { return "未设置上限" }
        if usage >= limit { return "已达上限 · 阻断结果待服务确认" }
        if Double(usage) / Double(limit) >= Double(rule.warningPercent) / 100 { return "接近每日上限" }
        return "未达每日上限"
    }
    private var symbol: String {
        guard let usage, let rule = application.rule, let limit = rule.limitBytes else { return "app" }
        if usage >= limit { return "exclamationmark.octagon" }
        if Double(usage) / Double(limit) >= Double(rule.warningPercent) / 100 { return "exclamationmark.triangle" }
        return "app"
    }

    var body: some View {
        Button(action: edit) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.title2).frame(width: 32, height: 34).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(application.identity.name).font(.headline).lineLimit(2)
                        Spacer(minLength: 4)
                        Text(UsageFormatter.bytes(usage)).monospacedDigit()
                    }
                    if let limit = application.rule?.limitBytes {
                        Text("每日上限 \(UsageFormatter.bytes(limit))").font(.caption).foregroundStyle(.secondary)
                        if let usage {
                            ProgressView(value: min(Double(usage) / Double(limit), 1))
                                .accessibilityLabel("每日额度使用比例")
                                .accessibilityValue("\(Int(min(Double(usage) / Double(limit), 1) * 100))%")
                        }
                    }
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("查看应用详情并编辑每日额度")
    }
}
