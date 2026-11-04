import FlowQuotaCore
import SwiftUI

struct ProtectionBanner: View {
    let state: AppState

    private var title: String {
        guard state.connected else { return "保护未就绪 · 服务未连接" }
        guard state.snapshotIsCurrent else { return "保护状态未知 · 数据已过期" }
        switch state.snapshot?.readiness {
        case .notInstalled: return "保护未就绪 · 尚未安装扩展"
        case .approvalRequired: return "保护未就绪 · 等待系统批准"
        case .failed: return "保护异常 · 请检查组件"
        case .ready: return "服务报告：保护组件已就绪"
        case nil: return "保护状态未知"
        }
    }
    private var symbol: String {
        state.usageAvailable ? "shield.lefthalf.filled" : "exclamationmark.shield"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline)
            if let message = state.snapshot?.message, !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                Text("安装并批准网络保护组件后，才能计量与执行额度。打开界面不代表保护已经生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !state.connected {
                Button("启用本地服务", systemImage: "power") { state.enableAgent() }
                    .disabled(state.busy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

struct ServiceFeedback: View {
    let state: AppState
    var body: some View {
        if let operation = state.operation {
            HStack { ProgressView().controlSize(.small); Text(operation).font(.caption) }
                .accessibilityElement(children: .combine)
        }
        if let error = state.connectionError {
            Label(error, systemImage: "network.slash")
                .font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
        if let error = state.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
        if let notice = state.notice {
            Label(notice, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
        }
    }
}
