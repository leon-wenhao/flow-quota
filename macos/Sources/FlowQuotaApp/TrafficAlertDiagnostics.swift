import Foundation

/// The current IPC exposes a human-readable status rather than typed alert issues.
/// Hide only exact healthy messages emitted by this service; unknown text remains
/// visible so new failure modes cannot disappear behind an optimistic keyword filter.
enum TrafficAlertDiagnostics {
    static func warning(in message: String) -> String? {
        let routineMessages = [
            "每日接口预警运行中。", "每日接口预警已关闭。",
            "接口短时预警运行中；未知来源不影响接口提醒。",
            "接口短时预警等待连续采样。", "接口短时预警已关闭。",
            "应用短时预警运行中；共享下载服务不推测原始请求方。",
            "应用短时预警等待连续采样。", "应用短时预警已关闭。",
            "接口短时窗口已清空；等待连续采样。",
            "应用短时窗口已清空；等待连续采样。",
            "接口短时窗口待建立。", "应用短时窗口待建立。",
            "短时预警尚未开始。"
        ]
        let remaining = routineMessages.reduce(message) { $0.replacingOccurrences(of: $1, with: "") }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return remaining.isEmpty ? nil : remaining
    }
}
