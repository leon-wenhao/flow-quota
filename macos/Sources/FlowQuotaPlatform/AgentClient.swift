import Foundation
import FlowQuotaCore
import ServiceManagement

/// UI access to the agent. Rule ACK is the only signal that a save succeeded.
@MainActor public final class AgentClient: AgentServiceClient {
    public init() {}

    public func enableAgent() async throws {
        try await registerAgent(startMonitoring: true)
    }

    private func registerAgent(startMonitoring: Bool) async throws {
        let service = SMAppService.agent(plistName: AgentEndpoint.launchAgentPlist)
        if service.status != .enabled { try service.register() }
        guard service.status == .enabled else {
            throw PlatformError.unavailable("请在系统设置的登录项中允许 Flow Quota 后台服务，然后重试。")
        }
        if startMonitoring { try await requireAcknowledgement(.startMonitoring) }
    }

    /// Explicit repair for retained ad-hoc helpers after a rebuild. Never used once
    /// a traffic extension is embedded; stopping a real engine needs its own ACK.
    public func repairDevelopmentAgent() async throws {
        try await repairDevelopmentAgent(startMonitoring: true)
    }

    /// Development diagnostics may repair registration without starting either sampler.
    /// The helper must also be launched with FLOW_QUOTA_VERIFY_PAUSED=1 for a cold start.
    public func repairDevelopmentAgent(startMonitoring: Bool) async throws {
        let app = Bundle.main.bundleURL
        let extensionFolder = app.appendingPathComponent("Contents/Library/SystemExtensions")
        guard Bundle.main.object(forInfoDictionaryKey: "FlowQuotaDevelopmentBuild") as? Bool == true,
              !FileManager.default.fileExists(atPath: extensionFolder.path) else {
            throw PlatformError.unavailable("该构建不能使用开发服务修复；请先通过正式流程停止保护。")
        }
        guard startMonitoring || ProcessInfo.processInfo.environment["FLOW_QUOTA_VERIFY_PAUSED"] == "1" else {
            throw PlatformError.unavailable("暂停修复前须设置专用启动环境，避免冷启动时启动采集。")
        }
        let service = SMAppService.agent(plistName: AgentEndpoint.launchAgentPlist)
        if service.status != .notRegistered { try await service.unregister() }
        try await registerAgent(startMonitoring: startMonitoring)
    }

    public func acknowledgeNotification(_ key: QuotaNotificationKey) async throws {
        try await requireAcknowledgement(.acknowledgeNotification(key))
    }

    public func fetchSnapshot() async throws -> AgentSnapshot {
        guard case .snapshot(let state) = try await send(.snapshot) else {
            throw PlatformError.malformedReply
        }
        return state
    }

    public func fetchApplicationTimeline(_ query: ApplicationTimelineQuery) async throws -> ApplicationUsageTimeline {
        guard case .applicationTimeline(let timeline) = try await send(.applicationTimeline(query)),
              timeline.query == query else { throw PlatformError.malformedReply }
        return timeline
    }

    public func saveRule(appKey: String, rule: QuotaRule) async throws {
        try await requireAcknowledgement(.saveRule(appKey: appKey, rule: rule))
    }

    public func saveRule(appKey: String, rule: QuotaRule, category: TrafficCategory) async throws {
        try await requireAcknowledgement(.saveCategoryRule(category: category, appKey: appKey, rule: rule))
    }

    public func saveTrafficAlertPolicy(_ policy: TrafficAlertPolicy, category: TrafficCategory) async throws {
        try await requireAcknowledgement(.saveCategoryTrafficAlertPolicy(category: category, policy: policy))
    }

    public func fetchTrafficAlertHistory(day: String, offset: Int, category: TrafficCategory) async throws -> [TrafficAlertEvent] {
        guard case .trafficAlertHistory(let events) = try await send(.categoryTrafficAlertHistory(category: category, day: day, offset: offset)) else {
            throw PlatformError.malformedReply
        }
        return events
    }

    public func setHotspotOverride(_ marked: Bool) async throws {
        try await requireAcknowledgement(.setHotspotOverride(marked))
    }

    public func fetchTrafficAlertHistory(day: String, offset: Int) async throws -> [TrafficAlertEvent] {
        guard case .trafficAlertHistory(let events) = try await send(.trafficAlertHistory(day: day, offset: offset)) else {
            throw PlatformError.malformedReply
        }
        return events
    }

    public func saveTrafficAlertPolicy(_ policy: TrafficAlertPolicy) async throws {
        try await requireAcknowledgement(.saveTrafficAlertPolicy(policy))
    }

    public func acknowledgeTrafficAlert(id: String) async throws {
        try await requireAcknowledgement(.acknowledgeTrafficAlert(id: id))
    }

    public func stopProtection() async throws {
        try await requireAcknowledgement(.stopProtection)
    }

    private func requireAcknowledgement(_ request: AgentRequest) async throws {
        guard case .acknowledged = try await send(request) else {
            throw PlatformError.malformedReply
        }
    }

    private func send(_ request: AgentRequest) async throws -> AgentReply {
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app" else {
            throw PlatformError.unavailable("请运行构建脚本生成的 Flow Quota.app；命令行二进制不包含后台服务。")
        }
        let helper = appURL.appendingPathComponent("Contents/MacOS/FlowQuotaAgent")
        let requirement = try PeerRequirement.string(forExecutable: helper)
        let payload = try JSONEncoder().encode(request)
        let connection = NSXPCConnection(machServiceName: AgentEndpoint.machService)
        connection.remoteObjectInterface = NSXPCInterface(with: AgentXPCProtocol.self)
        connection.setCodeSigningRequirement(requirement)

        try Task.checkCancellation()
        let completion = XPCCompletion(connection: connection)
        connection.interruptionHandler = { completion.fail("本地服务连接已中断。") }
        connection.invalidationHandler = { completion.fail("本地服务不可用，请先启用本地服务。") }
        connection.resume()
        let data: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard completion.install(continuation) else { return }
                let remote = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
                    completion.fail(error.localizedDescription)
                }
                guard let proxy = remote as? any AgentXPCProtocol else {
                    completion.fail("无法连接本地服务接口。")
                    return
                }
                completion.startTimeout()
                proxy.perform(payload) { response, error in
                    if let error { completion.fail(error) }
                    else if let response, response.count <= AgentEndpoint.maximumMessageBytes {
                        completion.succeed(response)
                    } else { completion.fail("本地服务响应无效或过大。") }
                }
            }
        } onCancel: {
            completion.cancel()
        }
        return try JSONDecoder().decode(AgentReply.self, from: data)
    }
}
