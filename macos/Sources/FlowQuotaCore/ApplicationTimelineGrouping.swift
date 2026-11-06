import Foundation

/// Shared display rules and ranking for persistent app attribution and session Clash sources.
/// Filtering happens before ranking so a hidden proxy never leaks into “other applications”.
public enum ApplicationTimelineGrouping {
    public static func make(query: ApplicationTimelineQuery, rows: [ApplicationUsageBucket],
                            clashNotice: String? = nil) throws -> ApplicationUsageTimeline {
        var visible: [ApplicationUsageBucket] = []
        var totals: [String: Int64] = [:]
        for row in rows {
            guard row.uploadedBytes >= 0, row.downloadedBytes >= 0, row.sampleCount > 0,
                  row.appKey == nil || row.clashSourceID == nil else { throw TimelineError.invalid }
            var name = row.name
            if let key = row.appKey {
                let source = SystemProcessClassification(identity: AppIdentity(key: key, name: row.name))
                guard source.visibleInApplicationUsage else { continue }
                name = source.displayName
            }
            let mapped = ApplicationUsageBucket(appKey: row.appKey, name: name,
                startMilliseconds: row.startMilliseconds, uploadedBytes: row.uploadedBytes,
                downloadedBytes: row.downloadedBytes, sampleCount: row.sampleCount,
                clashSourceID: row.clashSourceID)
            visible.append(mapped)
            totals[row.sourceID] = try add(totals[row.sourceID] ?? 0, add(row.uploadedBytes, row.downloadedBytes))
        }
        _ = try totals.values.reduce(Int64(0)) { try add($0, $1) }
        let top = Set(totals.keys.filter { $0 != "remaining" }.sorted {
            totals[$0] == totals[$1] ? $0 < $1 : totals[$0]! > totals[$1]!
        }.prefix(ApplicationUsageTimeline.maximumNamedSources))
        var grouped: [String: ApplicationUsageBucket] = [:]
        for row in visible {
            let named = top.contains(row.sourceID)
            let key = named ? row.id : "remaining:\(row.startMilliseconds)"
            let previous = grouped[key]
            grouped[key] = ApplicationUsageBucket(appKey: named ? row.appKey : nil,
                name: named ? row.name : "其他应用", startMilliseconds: row.startMilliseconds,
                uploadedBytes: try add(previous?.uploadedBytes ?? 0, row.uploadedBytes),
                downloadedBytes: try add(previous?.downloadedBytes ?? 0, row.downloadedBytes),
                sampleCount: try add(previous?.sampleCount ?? 0, row.sampleCount),
                clashSourceID: named ? row.clashSourceID : nil)
        }
        guard grouped.count <= ApplicationUsageTimeline.maximumRows else { throw TimelineError.invalid }
        return ApplicationUsageTimeline(query: query, bucketMinutes: query.bucketMinutes,
            buckets: grouped.values.sorted {
                $0.startMilliseconds == $1.startMilliseconds ? $0.sourceID < $1.sourceID
                    : $0.startMilliseconds < $1.startMilliseconds
            }, clashNotice: clashNotice)
    }

    private static func add(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw TimelineError.invalid }
        return value
    }

    private enum TimelineError: LocalizedError {
        case invalid
        var errorDescription: String? { "应用分时归因数据无效或超出整数范围。" }
    }
}
