import Foundation

public enum NetworkState: String, Codable, Sendable {
    case unknown, ordinary, hotspot, expensive

    /// All available paths count, in separate accounting categories.
    public var countsTraffic: Bool { trafficCategory != nil }
}

public enum ProtectionReadiness: String, Codable, Sendable {
    case notInstalled, approvalRequired, ready, failed
}

public struct ApplicationSnapshot: Codable, Sendable, Identifiable {
    public var id: String { identity.key }
    public let identity: AppIdentity
    public let rule: QuotaRule?
    public let usage: DailyUsage

    public init(identity: AppIdentity, rule: QuotaRule?, usage: DailyUsage) {
        self.identity = identity
        self.rule = rule
        self.usage = usage
    }
}

public struct AgentSnapshot: Codable, Sendable {
    public let generatedAt: Date
    public let network: NetworkState
    public let readiness: ProtectionReadiness
    public let applications: [ApplicationSnapshot]
    public let message: String
    public let monitoring: MonitoringStatus
    /// Service-confirmed collection state, distinct from application attribution health.
    /// Missing on older services; callers must present an unknown state, not infer off.
    public let samplingEnabled: Bool?
    public let sampledAt: Date?
    public let notifications: [ReminderNotification]
    public let coverageMessage: String
    public let interfaceUsage: InterfaceUsage?
    public let interfaceSampledAt: Date?
    public let interfaceMessage: String
    public let trafficAlertPolicy: TrafficAlertPolicy?
    public let trafficAlertEvents: [TrafficAlertEvent]
    public let pendingTrafficAlerts: [TrafficAlertEvent]
    public let trafficAlertMessage: String
    public let trafficCategories: [TrafficCategorySnapshot]?
    public let mihomoProxy: MihomoProxySnapshot?

    public init(generatedAt: Date, network: NetworkState, readiness: ProtectionReadiness,
                applications: [ApplicationSnapshot], message: String,
                monitoring: MonitoringStatus = .unavailable, samplingEnabled: Bool? = nil, sampledAt: Date? = nil,
                notifications: [ReminderNotification] = [], coverageMessage: String = "",
                interfaceUsage: InterfaceUsage? = nil, interfaceSampledAt: Date? = nil,
                interfaceMessage: String = "接口总量尚未就绪。",
                trafficAlertPolicy: TrafficAlertPolicy? = nil,
                trafficAlertEvents: [TrafficAlertEvent] = [], pendingTrafficAlerts: [TrafficAlertEvent] = [],
                trafficAlertMessage: String = "短时预警尚未开始。",
                trafficCategories: [TrafficCategorySnapshot]? = nil,
                mihomoProxy: MihomoProxySnapshot? = nil) {
        self.generatedAt = generatedAt
        self.network = network
        self.readiness = readiness
        self.applications = applications
        self.message = message
        self.monitoring = monitoring
        self.samplingEnabled = samplingEnabled
        self.sampledAt = sampledAt
        self.notifications = notifications
        self.coverageMessage = coverageMessage
        self.interfaceUsage = interfaceUsage
        self.interfaceSampledAt = interfaceSampledAt
        self.interfaceMessage = interfaceMessage
        self.trafficAlertPolicy = trafficAlertPolicy
        self.trafficAlertEvents = trafficAlertEvents
        self.pendingTrafficAlerts = pendingTrafficAlerts
        self.trafficAlertMessage = trafficAlertMessage
        self.trafficCategories = trafficCategories
        self.mihomoProxy = mihomoProxy
    }
}
