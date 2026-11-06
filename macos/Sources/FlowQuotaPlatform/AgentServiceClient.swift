import FlowQuotaCore

/// Service boundary for UI state tests; production always uses the verified XPC client.
@MainActor public protocol AgentServiceClient: AnyObject {
    func enableAgent() async throws
    func repairDevelopmentAgent() async throws
    func fetchApplicationTimeline(_ query: ApplicationTimelineQuery) async throws -> ApplicationUsageTimeline
    func fetchTrafficAlertDetails(id: String, day: String, category: TrafficCategory) async throws -> TrafficAlertEvent
    func fetchSnapshot() async throws -> AgentSnapshot
    func saveRule(appKey: String, rule: QuotaRule) async throws
    func setHotspotOverride(_ marked: Bool) async throws
    func acknowledgeNotification(_ key: QuotaNotificationKey) async throws
    func fetchTrafficAlertHistory(day: String, offset: Int) async throws -> [TrafficAlertEvent]
    func saveTrafficAlertPolicy(_ policy: TrafficAlertPolicy) async throws
    func acknowledgeTrafficAlert(id: String) async throws
    func saveRule(appKey: String, rule: QuotaRule, category: TrafficCategory) async throws
    func saveTrafficAlertPolicy(_ policy: TrafficAlertPolicy, category: TrafficCategory) async throws
    func fetchTrafficAlertHistory(day: String, offset: Int, category: TrafficCategory) async throws -> [TrafficAlertEvent]
    func stopProtection() async throws
}

// Existing metered-only clients remain usable, but never silently write an
// ordinary-network setting into the metered ledger.
extension AgentServiceClient {
    public func fetchTrafficAlertDetails(id: String, day: String, category: TrafficCategory) async throws -> TrafficAlertEvent {
        throw PlatformError.unavailable("当前服务不支持预警应用明细，请更新服务。")
    }

    public func fetchApplicationTimeline(_ query: ApplicationTimelineQuery) async throws -> ApplicationUsageTimeline {
        throw PlatformError.unavailable("当前服务不支持应用分时记录，请更新服务。")
    }

    public func saveRule(appKey: String, rule: QuotaRule, category: TrafficCategory) async throws {
        guard category == .metered else { throw PlatformError.unavailable("服务不支持分类提醒，请更新服务。") }
        try await saveRule(appKey: appKey, rule: rule)
    }
    public func saveTrafficAlertPolicy(_ policy: TrafficAlertPolicy, category: TrafficCategory) async throws {
        guard category == .metered else { throw PlatformError.unavailable("服务不支持分类提醒，请更新服务。") }
        try await saveTrafficAlertPolicy(policy)
    }
    public func fetchTrafficAlertHistory(day: String, offset: Int, category: TrafficCategory) async throws -> [TrafficAlertEvent] {
        guard category == .metered else { throw PlatformError.unavailable("服务不支持分类记录，请更新服务。") }
        return try await fetchTrafficAlertHistory(day: day, offset: offset)
    }
}
