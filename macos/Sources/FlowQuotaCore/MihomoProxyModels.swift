import Foundation

/// A live, session-scoped view of Mihomo's controller API. It is separate from
/// the physical interface ledger and the nettop application ledger.
public enum MihomoProxyStatus: String, Codable, Sendable {
    case paused, observing, stale, unavailable
}

public struct MihomoProxySource: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let displayName: String
    public let connectionCount: Int
    public let appIdentity: AppIdentity?
    public let siteName: String?
    public let viaClash: Bool?
    public let uploadedBytes: Int64
    public let downloadedBytes: Int64

    public init(id: String, displayName: String, connectionCount: Int,
                uploadedBytes: Int64, downloadedBytes: Int64,
                appIdentity: AppIdentity? = nil, siteName: String? = nil, viaClash: Bool? = true) {
        self.id = id
        self.displayName = displayName
        self.connectionCount = connectionCount
        self.appIdentity = appIdentity
        self.siteName = siteName
        self.viaClash = viaClash
        self.uploadedBytes = uploadedBytes
        self.downloadedBytes = downloadedBytes
    }

    public var totalBytes: Int64? {
        let (total, overflow) = uploadedBytes.addingReportingOverflow(downloadedBytes)
        return overflow ? nil : total
    }
}

public struct MihomoProxySnapshot: Codable, Sendable, Equatable {
    public let status: MihomoProxyStatus
    public let day: String?
    public let category: TrafficCategory?
    public let activeConnectionCount: Int
    public let uploadedBytes: Int64
    public let downloadedBytes: Int64
    public let sources: [MihomoProxySource]
    public let sampledAt: Date?
    public let message: String

    public init(status: MihomoProxyStatus, activeConnectionCount: Int = 0,
                uploadedBytes: Int64 = 0, downloadedBytes: Int64 = 0,
                sources: [MihomoProxySource] = [], sampledAt: Date? = nil,
                message: String = "", day: String? = nil, category: TrafficCategory? = nil) {
        self.status = status
        self.day = day
        self.category = category
        self.activeConnectionCount = activeConnectionCount
        self.uploadedBytes = uploadedBytes
        self.downloadedBytes = downloadedBytes
        self.sources = sources
        self.sampledAt = sampledAt
        self.message = message
    }

    public var totalBytes: Int64? {
        let (total, overflow) = uploadedBytes.addingReportingOverflow(downloadedBytes)
        return overflow ? nil : total
    }
}
