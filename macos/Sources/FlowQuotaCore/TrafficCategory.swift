import Foundation

/// Accounting scope, separate from the evidence used to classify a path.
/// Expensive is a cost signal, not proof of a phone hotspot.
public enum TrafficCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case metered, ordinary

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .metered: "热点／高成本"
        case .ordinary: "普通网络"
        }
    }
}

extension NetworkState {
    public var trafficCategory: TrafficCategory? {
        switch self {
        case .expensive, .hotspot: .metered
        case .ordinary: .ordinary
        case .unknown: nil
        }
    }
}

/// Current-day durable data for ONE category. Missing interface data is unknown;
/// an absent category in an old service must not be shown as zero ordinary usage.
public struct TrafficCategorySnapshot: Codable, Sendable {
    public let category: TrafficCategory
    public let applications: [ApplicationSnapshot]
    public let applicationsAvailable: Bool
    public let sampledAt: Date?
    public let interfaceUsage: InterfaceUsage?
    public let interfaceSampledAt: Date?
    public let interfaceMessage: String
    public let trafficAlertPolicy: TrafficAlertPolicy
    public let trafficAlertEvents: [TrafficAlertEvent]
    /// Nil on older services; empty on v6 before the first measured interval.
    public let interfaceUsageMinutes: [InterfaceUsageMinute]?
    /// Ephemeral Clash attribution, never part of the durable application ledger.
    public let mihomoProxy: MihomoProxySnapshot?

    public init(category: TrafficCategory, applications: [ApplicationSnapshot], applicationsAvailable: Bool,
                sampledAt: Date?, interfaceUsage: InterfaceUsage?, interfaceSampledAt: Date?,
                interfaceMessage: String, trafficAlertPolicy: TrafficAlertPolicy,
                trafficAlertEvents: [TrafficAlertEvent], interfaceUsageMinutes: [InterfaceUsageMinute]? = nil,
                mihomoProxy: MihomoProxySnapshot? = nil) {
        self.category = category
        self.applications = applications
        self.applicationsAvailable = applicationsAvailable
        self.sampledAt = sampledAt
        self.interfaceUsage = interfaceUsage
        self.interfaceSampledAt = interfaceSampledAt
        self.interfaceMessage = interfaceMessage
        self.trafficAlertPolicy = trafficAlertPolicy
        self.trafficAlertEvents = trafficAlertEvents
        self.interfaceUsageMinutes = interfaceUsageMinutes
        self.mihomoProxy = mihomoProxy
    }
}

extension AgentSnapshot {
    public func usage(for category: TrafficCategory) -> TrafficCategorySnapshot? {
        if let trafficCategories { return trafficCategories.first { $0.category == category } }
        // Legacy IPC only contains the metered ledger. Do not fabricate ordinary data.
        guard category == .metered, let policy = trafficAlertPolicy else { return nil }
        return TrafficCategorySnapshot(category: .metered, applications: applications,
            applicationsAvailable: sampledAt != nil, sampledAt: sampledAt,
            interfaceUsage: interfaceUsage, interfaceSampledAt: interfaceSampledAt,
            interfaceMessage: interfaceMessage, trafficAlertPolicy: policy, trafficAlertEvents: trafficAlertEvents)
    }
}
