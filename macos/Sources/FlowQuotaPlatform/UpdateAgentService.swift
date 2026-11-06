import FlowQuotaCore
import ServiceManagement

@MainActor public protocol UpdateAgentService: AnyObject {
    func isRegisteredForUpdate() throws -> Bool
    func fetchSnapshot() async throws -> AgentSnapshot
    func stopProtection() async throws
    func unregisterForUpdate() async throws
    func restoreAfterUpdate(resumeSampling: Bool) async throws
}

extension AgentClient: UpdateAgentService {
    public func isRegisteredForUpdate() throws -> Bool {
        switch SMAppService.agent(plistName: AgentEndpoint.launchAgentPlist).status {
        case .notRegistered, .notFound: return false
        case .enabled: return true
        case .requiresApproval:
            throw PlatformError.unavailable("后台服务需要系统批准，请先在登录项中允许 Flow Quota 后重试更新。")
        @unknown default:
            throw PlatformError.unavailable("后台服务注册状态未知，不能继续安装。")
        }
    }

    public func unregisterForUpdate() async throws {
        let service = SMAppService.agent(plistName: AgentEndpoint.launchAgentPlist)
        if service.status != .notRegistered { try await service.unregister() }
        guard service.status == .notRegistered else {
            throw PlatformError.unavailable("后台服务尚未完成注销，不能替换应用。")
        }
    }

    public func restoreAfterUpdate(resumeSampling: Bool) async throws {
        guard UpdateResumeStore().hasPendingInstallation else {
            throw PlatformError.unavailable("缺少更新恢复标记，不能自动恢复后台服务。")
        }
        try await registerAgent(startMonitoring: false)
        try await requireAcknowledgement(resumeSampling ? .startMonitoring : .stopProtection)
    }
}
