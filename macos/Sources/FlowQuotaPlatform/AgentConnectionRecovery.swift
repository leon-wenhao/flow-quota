import Foundation
import ServiceManagement

/// Only an explicit connect/repair action may replace an unreachable reminder helper.
/// Polling and failed business requests must never restart it or discard sampling baselines.
@MainActor struct AgentConnectionRecovery {
    let status: () -> SMAppService.Status
    let refreshApplication: () async throws -> Void
    let register: () throws -> Void
    let unregister: () async throws -> Void
    let verifyConnection: () async throws -> Void
    let startMonitoring: () async throws -> Void
    let allowsReplacement: Bool

    func connect(startMonitoring shouldStart: Bool, replacingRegistration: Bool = false) async throws {
        try Task.checkCancellation()
        if replacingRegistration {
            try await replaceRegistration()
            try await verifyConnection()
        } else {
            try await ensureRegistered()
            do {
                try await verifyConnection()
            } catch {
                guard allowsReplacement, Self.isConnectionFailure(error) else { throw error }
                // An enabled registration can still point to a running pre-upgrade
                // ad-hoc binary. Reap that process before registering the new bundle.
                try Task.checkCancellation()
                try await replaceRegistration()
                do { try await verifyConnection() }
                catch is CancellationError { throw CancellationError() }
                catch {
                    throw PlatformError.unavailable(
                        "后台服务已重新注册，但仍无法连接：\(error.localizedDescription) 请在通用设置的“服务与诊断”中查看状态。")
                }
            }
        }
        try Task.checkCancellation()
        // Keep the ACK outside the recovery catch: an agent-side error must not
        // restart a healthy service or turn an uncertain mutation into a retry.
        if shouldStart { try await startMonitoring() }
    }

    private func ensureRegistered() async throws {
        guard status() != .requiresApproval else { throw approvalRequired }
        if status() != .enabled {
            // Wait for fresh app metadata before ServiceManagement derives the
            // helper path and launch requirements from the containing bundle.
            try await refreshApplication()
            // Consent can change while LaunchServices is refreshing off-actor.
            guard status() != .requiresApproval else { throw approvalRequired }
            if status() != .enabled { try register() }
        }
        guard status() == .enabled else { throw approvalRequired }
    }

    private func replaceRegistration() async throws {
        guard allowsReplacement else {
            throw PlatformError.unavailable("该构建不能自动替换后台服务；请通过正式流程停止保护。")
        }
        guard status() != .requiresApproval else { throw approvalRequired }
        // SMAppService's async completion waits for process termination. Complete
        // the register pair even if cancellation arrives while unregistering.
        if status() != .notRegistered { try await unregister() }
        try await ensureRegistered()
        try Task.checkCancellation()
    }

    private var approvalRequired: PlatformError {
        .unavailable("请在系统设置的登录项中允许 Flow Quota 后台服务，然后重试。")
    }

    private static func isConnectionFailure(_ error: any Error) -> Bool {
        guard let error = error as? PlatformError else { return false }
        switch error {
        case .connectionFailed, .timeout: return true
        case .unavailable, .malformedReply: return false
        }
    }
}
