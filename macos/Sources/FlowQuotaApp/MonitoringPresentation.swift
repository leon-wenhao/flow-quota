import FlowQuotaCore
import SwiftUI

/// Shared application-sampler presentation; independent interface status is shown separately.
@MainActor struct MonitoringPresentation {
    let state: AppState

    var title: String {
        guard state.connected else { return "采样服务未连接" }
        guard state.snapshotIsCurrent else { return "采样状态已过期" }
        switch state.snapshot?.monitoring {
        case .unavailable: return "应用采集未就绪"
        case .collecting: return state.usageAvailable ? "应用采集中" : "等待首次应用采样"
        case .paused: return "应用采集已暂停"
        case .failed: return "应用采集异常"
        case nil: return "采样状态未知"
        }
    }

    var collecting: Bool {
        state.connected && state.snapshotIsCurrent && state.snapshot?.monitoring == .collecting
    }
    var failed: Bool {
        state.connected && state.snapshotIsCurrent && state.snapshot?.monitoring == .failed
    }
    var showsFailureReason: Bool {
        state.connected && state.snapshotIsCurrent
            && (state.snapshot?.monitoring == .failed || state.snapshot?.monitoring == .unavailable)
    }
    var statusColor: Color { failed ? .red : (collecting && state.usageAvailable ? .green : .orange) }
    var symbol: String {
        if failed { return "exclamationmark.triangle.fill" }
        if collecting { return state.usageAvailable ? "waveform.path" : "hourglass" }
        if state.connected && state.snapshotIsCurrent && state.snapshot?.monitoring == .paused {
            return "pause.circle.fill"
        }
        return "exclamationmark.circle.fill"
    }
    var summary: String {
        guard state.connected else { return "启用本地服务后开始采集。" }
        guard state.snapshotIsCurrent else { return "当前状态未知，请刷新服务状态。" }
        switch state.snapshot?.monitoring {
        case .paused: return "保留已观测用量；暂停期间的应用流量未知。"
        case .collecting:
            return state.usageAvailable ? "达到阈值时提醒，不阻断连接。" : "首次有效采样前，用量显示为未知。"
        case .failed, .unavailable, nil: return "应用用量暂不可用；接口状态请查看总量面板。"
        }
    }

}
