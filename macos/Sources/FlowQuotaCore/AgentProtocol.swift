import Foundation

public enum AgentRequest: Codable, Sendable {
    case snapshot
    case applicationTimeline(ApplicationTimelineQuery)
    case saveRule(appKey: String, rule: QuotaRule)
    case saveCategoryRule(category: TrafficCategory, appKey: String, rule: QuotaRule)
    case setHotspotOverride(Bool)
    case startMonitoring
    case trafficAlertDetails(category: TrafficCategory, day: String, id: String)
    case trafficAlertHistory(day: String, offset: Int)
    case saveTrafficAlertPolicy(TrafficAlertPolicy)
    case saveCategoryTrafficAlertPolicy(category: TrafficCategory, policy: TrafficAlertPolicy)
    case categoryTrafficAlertHistory(category: TrafficCategory, day: String, offset: Int)
    case acknowledgeTrafficAlert(id: String)
    case acknowledgeNotification(QuotaNotificationKey)
    case stopProtection
}

public enum AgentReply: Codable, Sendable {
    case snapshot(AgentSnapshot)
    case applicationTimeline(ApplicationUsageTimeline)
    case trafficAlertHistory([TrafficAlertEvent])
    case trafficAlertDetails(TrafficAlertEvent)
    case acknowledged
}

/// XPC only transports bounded encoded metadata, never packet payloads.
@objc public protocol AgentXPCProtocol {
    func perform(_ request: Data, reply: @escaping @Sendable (Data?, String?) -> Void)
}

public enum AgentEndpoint {
    public static let machService = "local.flowquota.agent"
    public static let launchAgentPlist = "local.flowquota.agent.plist"
    public static let maximumMessageBytes = 1_048_576
}
