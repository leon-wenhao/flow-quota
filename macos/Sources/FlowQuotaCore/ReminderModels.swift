import Foundation

/// Sampling readiness is independent of NetworkExtension protection readiness.
public enum MonitoringStatus: String, Codable, Sendable {
    case unavailable, collecting, paused, failed
}

/// Persisted counters propose a notification; only successful OS scheduling is acknowledged.
/// The legacy `.blocked` key means threshold reached, never a claim of enforcement.
public struct ReminderNotification: Codable, Sendable, Identifiable {
    public let key: QuotaNotificationKey
    public let appName: String
    public let usedBytes: Int64
    public let limitBytes: Int64

    public var id: String {
        // Retain legacy metered identifiers across upgrades; ordinary has its own namespace.
        let category = key.category == .ordinary ? "ordinary:" : ""
        return "flowquota:\(category)\(key.identity.day):\(key.identity.ruleVersion):\(key.kind.rawValue):\(key.identity.appKey)"
    }

    public init(key: QuotaNotificationKey, appName: String, usedBytes: Int64, limitBytes: Int64) {
        self.key = key
        self.appName = appName
        self.usedBytes = usedBytes
        self.limitBytes = limitBytes
    }
}
