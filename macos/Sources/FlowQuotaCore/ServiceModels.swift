import Foundation

public enum NetworkState: String, Codable, Sendable {
    case unknown, ordinary, hotspot
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

    public init(generatedAt: Date, network: NetworkState, readiness: ProtectionReadiness,
                applications: [ApplicationSnapshot], message: String) {
        self.generatedAt = generatedAt
        self.network = network
        self.readiness = readiness
        self.applications = applications
        self.message = message
    }
}
