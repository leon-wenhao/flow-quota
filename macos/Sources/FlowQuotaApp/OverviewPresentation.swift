import FlowQuotaCore
import Foundation

extension AppState {
    var networkName: String {
        guard connected, snapshotIsCurrent else { return "网络未知" }
        switch snapshot?.network {
        case .expensive: return "高成本网络"
        case .hotspot: return "手动热点"
        case .ordinary: return "普通网络"
        case .unknown, nil: return "网络未知"
        }
    }

    var interfaceSummary: String {
        guard connected else { return "服务未连接 · 用量未知" }
        guard snapshotIsCurrent else { return "状态已过期 · 请刷新" }
        guard interfaceUsageAvailable else {
            return snapshot?.monitoring == .paused ? "暂无有效累计 · 暂停期间流量未知" : "接口用量暂不可用 · 查看详情"
        }
        if snapshot?.monitoring == .paused { return "已保留今日累计 · 暂停期间流量未知" }
        return interfaceUsageIsPreserved ? "已保留今日累计 · 当前接口未计量" : "上传＋下载 · 仅含已观测流量"
    }

    /// Agent's existing diagnostic contract has two explicit error prefixes. Show the
    /// entire diagnostic on failure, including 128-source/256-event capacity errors.
    var trafficAlertWarning: String? {
        guard connected, snapshotIsCurrent, let message = snapshot?.trafficAlertMessage,
              message.contains("接口预警未完成：") || message.contains("应用预警覆盖不完整：") else { return nil }
        return message
    }
}
