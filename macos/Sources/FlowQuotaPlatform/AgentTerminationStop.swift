import Foundation
import FlowQuotaCore
import ServiceManagement

/// A quit action may remove an unreachable reminder helper. Never register/start a
/// service here, or apply this fallback to a future network filtering extension.
@MainActor struct AgentTerminationStop {
    let status: () -> SMAppService.Status
    let stop: () async throws -> Void
    let unregister: () async throws -> Void
    let allowsUnregister: Bool

    func run(onRecovery: @MainActor () -> Void) async throws {
        try Task.checkCancellation()
        // Also covers a previously connected helper that has since been removed.
        guard status() != .notRegistered else { return }
        do {
            try await stop()
        } catch {
            guard allowsUnregister, Self.isTransportFailure(error) else { throw error }
            try Task.checkCancellation()
            onRecovery()
            do {
                // The async SMAppService API waits for service termination. Its
                // synchronous counterpart only submits removal and is insufficient.
                try await unregister()
                guard status() == .notRegistered else {
                    throw PlatformError.unavailable("后台服务尚未完成注销。")
                }
            } catch let removalError {
                throw PlatformError.unavailable(
                    "停止请求失败：\(error.localizedDescription)；系统停止后台服务也未完成：\(removalError.localizedDescription)")
            }
        }
    }

    private static func isTransportFailure(_ error: any Error) -> Bool {
        guard let error = error as? PlatformError else { return false }
        switch error {
        case .connectionFailed, .timeout: return true
        case .unavailable, .malformedReply: return false
        }
    }
}

extension AgentClient {
    public func stopForTermination(onRecovery: @escaping @MainActor () -> Void) async throws {
        let service = SMAppService.agent(plistName: AgentEndpoint.launchAgentPlist)
        let operation = AgentTerminationStop(status: { service.status },
            stop: { try await self.stopProtection() },
            unregister: { try await service.unregister() },
            allowsUnregister: canReplaceReminderAgent)
        try await operation.run(onRecovery: onRecovery)
    }
}
