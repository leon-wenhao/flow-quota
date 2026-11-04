import Foundation

/// Stable platform identity (for example a verified signing identity), never a PID.
public struct AppIdentity: Codable, Hashable, Sendable {
    public let key: String
    public let name: String

    public init(key: String, name: String) {
        self.key = key
        self.name = name
    }
}

public enum RuleError: Error, Equatable, Sendable {
    case invalidLimit
    case invalidWarningPercent
    case invalidVersion
}

public struct QuotaRule: Codable, Equatable, Sendable {
    public let limitBytes: Int64?
    public let warningPercent: Int
    public let version: Int64

    public init(limitBytes: Int64?, warningPercent: Int = 80, version: Int64 = 1) throws {
        guard limitBytes == nil || limitBytes! > 0 else { throw RuleError.invalidLimit }
        guard (1...99).contains(warningPercent) else { throw RuleError.invalidWarningPercent }
        guard version > 0 else { throw RuleError.invalidVersion }
        self.limitBytes = limitBytes
        self.warningPercent = warningPercent
        self.version = version
    }

    // Decoded IPC and disk data must pass the same checks as UI input.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            limitBytes: values.decodeIfPresent(Int64.self, forKey: .limitBytes),
            warningPercent: values.decode(Int.self, forKey: .warningPercent),
            version: values.decode(Int64.self, forKey: .version)
        )
    }
}

public struct DailyUsage: Codable, Equatable, Sendable {
    public let appKey: String
    public let day: String
    public let uploadedBytes: Int64
    public let downloadedBytes: Int64

    public init(appKey: String, day: String, uploadedBytes: Int64, downloadedBytes: Int64) {
        self.appKey = appKey
        self.day = day
        self.uploadedBytes = uploadedBytes
        self.downloadedBytes = downloadedBytes
    }

    /// Saturates on overflow; invalid counters must never wrap into fresh budget.
    public var totalBytes: Int64 {
        let (total, overflow) = uploadedBytes.addingReportingOverflow(downloadedBytes)
        return overflow ? .max : total
    }
}
