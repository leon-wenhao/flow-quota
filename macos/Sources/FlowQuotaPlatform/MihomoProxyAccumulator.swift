import Foundation
import FlowQuotaCore

/// Session-only attribution. Baselines are disposable, while today's category
/// subtotals survive pauses and closed connections until the agent exits.
public struct MihomoProxyAccumulator: Sendable {
    private struct Previous: Sendable {
        let upload: Int64
        let download: Int64
        let sourceID: String
    }
    private struct Bucket: Sendable {
        var sources: [String: MihomoProxySource] = [:]
        var upload: Int64 = 0
        var download: Int64 = 0
        var sampledAt: Date?
        var limited = false
    }
    private var previousTotals: (upload: Int64, download: Int64)?
    private var previousConnections: [String: Previous] = [:]
    private var scope: String?
    private var previousUptime: UInt64?
    private var previousDate: Date?
    private var day: String?
    private var buckets: [TrafficCategory: Bucket] = [:]
    private let resolver = MihomoSourceResolver()
    private var minuteHistory = MihomoMinuteHistory()

    public init() {}

    public mutating func reset() {
        resetBaseline()
        day = nil
        buckets = [:]
        minuteHistory.reset()
    }

    /// Faults, pause and path changes invalidate continuity, never erase earned subtotals.
    public mutating func resetBaseline() {
        previousTotals = nil
        previousConnections = [:]
        scope = nil
        previousUptime = nil
        previousDate = nil
    }

    public mutating func consume(_ response: MihomoAPIResponse, scope: String, capturedAt: Date,
                                 category: TrafficCategory? = .metered,
                                 uptime: UInt64 = SamplingClock.nowNanoseconds) throws -> MihomoProxySnapshot {
        let currentDay = try LocalDay.key(for: capturedAt, in: .current)
        if day != currentDay {
            reset()
            day = currentDay
        }
        minuteHistory.setDay(currentDay)
        let currentScope = "\(currentDay):\(category?.rawValue ?? "unknown"):\(scope)"
        let continuous = self.scope == currentScope && previousTotals.map {
            $0.upload <= response.uploadTotal && $0.download <= response.downloadTotal
        } == true && previousUptime.map { uptime > $0 && uptime - $0 <= 8_000_000_000 } == true
            && previousDate.map { (0...8).contains(capturedAt.timeIntervalSince($0)) } == true
        var bucket = category.flatMap { buckets[$0] } ?? Bucket()
        // Closed connections retain their observed use but no longer appear active.
        bucket.sources = bucket.sources.mapValues { copying($0, count: 0) }
        if continuous, category != nil, let previousTotals {
            bucket.upload = try adding(bucket.upload, response.uploadTotal - previousTotals.upload)
            bucket.download = try adding(bucket.download, response.downloadTotal - previousTotals.download)
        }
        var nextConnections: [String: Previous] = [:]
        var minuteDeltas: [String: (source: MihomoProxySource, upload: Int64, download: Int64)] = [:]
        for connection in response.connections {
            let source = resolver.source(for: connection)
            nextConnections[connection.id] = Previous(upload: connection.upload,
                download: connection.download, sourceID: source.id)
            guard category != nil else { continue }
            // A changed process/domain or rollback has no trustworthy interval owner.
            let old = previousConnections[connection.id]
            let valid = continuous && old?.sourceID == source.id
                && (old?.upload ?? Int64.max) <= connection.upload
                && (old?.download ?? Int64.max) <= connection.download
            let upload = valid ? connection.upload - (old?.upload ?? 0) : 0
            let download = valid ? connection.download - (old?.download ?? 0) : 0
            // Bound memory without assigning overflow traffic to an invented owner.
            guard bucket.sources[source.id] != nil || bucket.sources.count < 128 else {
                bucket.limited = true
                continue
            }
            if valid {
                let previousDelta = minuteDeltas[source.id]
                minuteDeltas[source.id] = (source, try adding(previousDelta?.upload ?? 0, upload),
                    try adding(previousDelta?.download ?? 0, download))
            }
            let prior = bucket.sources[source.id]
            bucket.sources[source.id] = copying(source, count: (prior?.connectionCount ?? 0) + 1,
                upload: try adding(prior?.uploadedBytes ?? 0, upload),
                download: try adding(prior?.downloadedBytes ?? 0, download))
        }
        if let category {
            for delta in minuteDeltas.values {
                try minuteHistory.record(source: delta.source, category: category, at: capturedAt,
                    upload: delta.upload, download: delta.download)
            }
        }
        previousTotals = (response.uploadTotal, response.downloadTotal)
        previousConnections = nextConnections
        self.scope = currentScope
        previousUptime = uptime
        previousDate = capturedAt
        if let category {
            bucket.sampledAt = capturedAt
            buckets[category] = bucket
        }
        return snapshot(category: category, day: currentDay, status: .observing)
    }

    public func snapshot(category: TrafficCategory?, day requestedDay: String,
                         status: MihomoProxyStatus, message: String = "") -> MihomoProxySnapshot {
        let bucket = requestedDay == day ? category.flatMap { buckets[$0] } : nil
        let sources = (bucket?.sources.values.map { $0 } ?? []).sorted {
            let left = $0.totalBytes ?? 0
            let right = $1.totalBytes ?? 0
            return left == right ? $0.id < $1.id : left > right
        }
        let detail = "Clash 来源仅计本次服务运行期间的连续观测；未捕获的已关闭连接无法细分。"
        let limit = bucket?.limited == true ? " 来源已达 128 项上限，部分明细未展示。" : ""
        return MihomoProxySnapshot(status: status,
            activeConnectionCount: sources.reduce(0) { $0 + $1.connectionCount },
            uploadedBytes: bucket?.upload ?? 0, downloadedBytes: bucket?.download ?? 0,
            sources: sources, sampledAt: bucket?.sampledAt,
            message: (message.isEmpty ? detail : message) + limit, day: requestedDay, category: category)
    }

    /// Aggregates retained only in this service session; caller validates query dates first.
    public func timelineRows(_ query: ApplicationTimelineQuery) throws -> [ApplicationUsageBucket] {
        try minuteHistory.rows(for: query)
    }

    public func timelineNotice(for category: TrafficCategory) -> String {
        minuteHistory.notice(for: category)
            + (buckets[category]?.limited == true ? " 来源已达 128 项上限，部分明细未展示。" : "")
    }

    private func copying(_ source: MihomoProxySource, count: Int,
                         upload: Int64? = nil, download: Int64? = nil) -> MihomoProxySource {
        MihomoProxySource(id: source.id, displayName: source.displayName, connectionCount: count,
            uploadedBytes: upload ?? source.uploadedBytes, downloadedBytes: download ?? source.downloadedBytes,
            appIdentity: source.appIdentity, siteName: source.siteName, viaClash: source.viaClash)
    }

    private func adding(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw PlatformError.unavailable("Mihomo API 流量超出整数范围。") }
        return value
    }
}
