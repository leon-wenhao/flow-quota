import Foundation

/// Snapshot of visible feedback, ordered so an error cannot be hidden by success.
@MainActor struct ServiceFeedbackPresentation {
    struct Entry {
        let title: String
        let detail: String
        var isError = false
    }
    let entries: [Entry]
    let working: Bool
    var hasError: Bool { entries.contains(where: \.isError) }
    var title: String { entries.first?.title ?? "仅保存在本机" }
    var detail: String { entries.isEmpty ? "用量与配置仅保存在本机。" : entries.map(\.detail).joined(separator: "\n\n") }
    var symbol: String {
        if hasError { return "exclamationmark.triangle" }
        return entries.isEmpty ? "internaldrive" : "info.circle"
    }

    init(state: AppState) {
        var result: [Entry] = []
        for (title, detail) in [
            ("服务连接异常", state.connectionError),
            ("操作失败", state.errorMessage),
            ("预警通知异常", state.trafficAlertDelivery.errorMessage),
            ("通知授权异常", state.notifications.errorMessage),
            ("应用提醒异常", state.reminderDelivery.errorMessage)
        ] {
            if let detail { result.append(Entry(title: title, detail: detail, isError: true)) }
        }
        if let operation = state.operation {
            result.append(Entry(title: operation, detail: operation))
        }
        if state.notifications.requesting {
            result.append(Entry(title: "等待通知授权", detail: "等待系统通知授权；尚未确认授权结果。"))
        }
        if let notice = state.notice {
            result.append(Entry(title: notice.hasPrefix("流量预警配置已持久化") ? "预警已保存" : "操作已完成", detail: notice))
        }
        entries = result
        working = !result.contains(where: \.isError) && (state.busy || state.notifications.requesting)
    }
}
