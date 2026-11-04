import Foundation

public enum AgentRequest: Codable, Sendable {
    case snapshot
    case saveRule(appKey: String, rule: QuotaRule)
    case setHotspotOverride(Bool)
    case stopProtection
}

public enum AgentReply: Codable, Sendable {
    case snapshot(AgentSnapshot)
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
