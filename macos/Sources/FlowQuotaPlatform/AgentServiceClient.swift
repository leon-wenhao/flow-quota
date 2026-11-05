import FlowQuotaCore

/// Service boundary for UI state tests; production always uses the verified XPC client.
@MainActor public protocol AgentServiceClient: AnyObject {
    func enableAgent() async throws
    func repairDevelopmentAgent() async throws
    func fetchSnapshot() async throws -> AgentSnapshot
    func saveRule(appKey: String, rule: QuotaRule) async throws
    func setHotspotOverride(_ marked: Bool) async throws
    func acknowledgeNotification(_ key: QuotaNotificationKey) async throws
    func fetchTrafficAlertHistory(day: String, offset: Int) async throws -> [TrafficAlertEvent]
    func saveTrafficAlertPolicy(_ policy: TrafficAlertPolicy) async throws
    func acknowledgeTrafficAlert(id: String) async throws
    func stopProtection() async throws
}
