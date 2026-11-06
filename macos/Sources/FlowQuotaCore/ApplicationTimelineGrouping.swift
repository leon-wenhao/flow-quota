import Foundation

/// Validate and order bounded timeline rows. The store resolves proxy parents
/// before calling this; raw evidence remains available through its own query.
public enum ApplicationTimelineGrouping {
    public static func make(query: ApplicationTimelineQuery, rows: [ApplicationUsageBucket],
                            clashNotice: String? = nil) throws -> ApplicationUsageTimeline {
        guard rows.count <= ApplicationUsageTimeline.maximumRows else { throw TimelineError.capacity }
        var seen = Set<String>()
        var mapped: [ApplicationUsageBucket] = []
        for row in rows {
            guard row.uploadedBytes >= 0, row.downloadedBytes >= 0, row.sampleCount > 0,
                  row.appKey == nil || row.clashSourceID == nil,
                  !row.uploadedBytes.addingReportingOverflow(row.downloadedBytes).overflow,
                  seen.insert(row.id).inserted else { throw TimelineError.invalid }
            let name = row.appKey.map {
                SystemProcessClassification(identity: AppIdentity(key: $0, name: row.name)).displayName
            } ?? row.name
            mapped.append(ApplicationUsageBucket(appKey: row.appKey, name: name,
                startMilliseconds: row.startMilliseconds, uploadedBytes: row.uploadedBytes,
                downloadedBytes: row.downloadedBytes, sampleCount: row.sampleCount,
                clashSourceID: row.clashSourceID))
        }
        return ApplicationUsageTimeline(query: query, bucketMinutes: query.bucketMinutes,
            buckets: mapped.sorted {
                $0.startMilliseconds == $1.startMilliseconds ? $0.sourceID < $1.sourceID
                    : $0.startMilliseconds < $1.startMilliseconds
            }, clashNotice: clashNotice)
    }

    private enum TimelineError: LocalizedError {
        case invalid, capacity
        var errorDescription: String? {
            switch self {
            case .invalid: "应用分时记录无效、重复或超出整数范围。"
            case .capacity: "应用明细超过容量，无法完整展示；接口总量仍独立保留，请缩短查询时段。"
            }
        }
    }
}
