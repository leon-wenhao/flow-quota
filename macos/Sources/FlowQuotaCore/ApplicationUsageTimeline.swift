import Foundation

/// Current-day, minute-aligned attribution query. The service validates dates and
/// bounds and returns at most 50 time buckets × (ten applications + remaining).
public struct ApplicationTimelineQuery: Codable, Sendable, Equatable, Hashable {
    public let day: String
    public let category: TrafficCategory
    public let start: Date
    public let end: Date
    public let appKey: String?
    public var bucketMinutes: Int { end.timeIntervalSince(start) <= 3_600 ? 5 : 30 }

    public init(day: String, category: TrafficCategory, start: Date, end: Date, appKey: String? = nil) {
        self.day = day
        self.category = category
        self.start = start
        self.end = end
        self.appKey = appKey
    }
}

public struct ApplicationUsageBucket: Codable, Sendable, Equatable, Identifiable {
    public var sourceID: String { clashSourceID.map { "clash:" + $0 } ?? appKey.map { "app:" + $0 } ?? "remaining" }
    public var id: String { "\(sourceID):\(startMilliseconds)" }
    /// Clash sources have their own namespace and are never quota application identities.
    public let clashSourceID: String?
    /// Nil with no Clash source denotes explicitly grouped remaining applications.
    public let appKey: String?
    public let name: String
    public let startMilliseconds: Int64
    public let uploadedBytes: Int64
    public let downloadedBytes: Int64
    public let sampleCount: Int64

    public init(appKey: String?, name: String, startMilliseconds: Int64,
                uploadedBytes: Int64, downloadedBytes: Int64, sampleCount: Int64, clashSourceID: String? = nil) {
        self.appKey = appKey
        self.clashSourceID = clashSourceID
        self.name = name
        self.startMilliseconds = startMilliseconds
        self.uploadedBytes = uploadedBytes
        self.downloadedBytes = downloadedBytes
        self.sampleCount = sampleCount
    }
}

public struct ApplicationUsageTimeline: Codable, Sendable, Equatable {
    public static let maximumNamedSources = 10
    public static let maximumTimeBuckets = 50
    public static let maximumRows = maximumTimeBuckets * (maximumNamedSources + 1)

    public let query: ApplicationTimelineQuery
    public let bucketMinutes: Int
    public let buckets: [ApplicationUsageBucket]
    public let clashNotice: String?

    public init(query: ApplicationTimelineQuery, bucketMinutes: Int, buckets: [ApplicationUsageBucket], clashNotice: String? = nil) {
        self.query = query
        self.bucketMinutes = bucketMinutes
        self.buckets = buckets
        self.clashNotice = clashNotice
    }
}
