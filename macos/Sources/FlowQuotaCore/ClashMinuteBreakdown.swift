import Foundation

/// Resolve at the finest stored granularity, BEFORE aggregating chart buckets or
/// days: an excess minute cannot borrow another minute's unused parent bytes.
public enum ClashMinuteBreakdown {
    public static func resolve(processes: [ApplicationUsageBucket], sources: [ClashMinuteUsage]) throws
        -> (rows: [ApplicationUsageBucket], notice: String?) {
        let children = Dictionary(grouping: sources, by: \.minute)
        let minutes = Dictionary(grouping: processes, by: \.startMilliseconds)
        var rows: [ApplicationUsageBucket] = []
        var notice: String?
        for (minute, records) in minutes {
            let parents = records.filter { row in
                row.appKey.map { ClashUsageBreakdown.isProxy(AppIdentity(key: $0, name: row.name)) } ?? false
            }
            rows += records.filter { row in !parents.contains(where: { $0.id == row.id }) }
            guard !parents.isEmpty else { continue }
            let upload = try parents.reduce(Int64(0)) { try ClashUsageBreakdown.add($0, $1.uploadedBytes) }
            let download = try parents.reduce(Int64(0)) { try ClashUsageBreakdown.add($0, $1.downloadedBytes) }
            let result = try ClashUsageBreakdown.split(upload: upload, download: download,
                sources: parents.count == 1 ? (children[minute] ?? []).map(\.source) : [])
            if parents.count > 1 { notice = "Clash 内核身份不唯一；相关用量完整保留为其他未识别。" }
            notice = result.notice ?? notice
            for source in result.sources {
                rows.append(ApplicationUsageBucket(appKey: nil, name: source.name, startMilliseconds: minute,
                    uploadedBytes: source.uploadedBytes, downloadedBytes: source.downloadedBytes,
                    sampleCount: parents.map(\.sampleCount).max() ?? 1, clashSourceID: source.id))
            }
        }
        return (rows, notice)
    }

    public static func group(_ rows: [ApplicationUsageBucket], start: Int64, step: Int64) throws -> [ApplicationUsageBucket] {
        guard step > 0, rows.allSatisfy({ $0.startMilliseconds >= start }) else { throw ClashBreakdownError.invalid }
        var grouped: [String: ApplicationUsageBucket] = [:]
        for row in rows {
            let minute = start + (row.startMilliseconds - start) / step * step
            let key = row.sourceID + ":" + String(minute)
            let old = grouped[key]
            guard old == nil || old?.name == row.name else { throw ClashBreakdownError.invalid }
            grouped[key] = ApplicationUsageBucket(appKey: row.appKey, name: row.name, startMilliseconds: minute,
                uploadedBytes: try ClashUsageBreakdown.add(old?.uploadedBytes ?? 0, row.uploadedBytes),
                downloadedBytes: try ClashUsageBreakdown.add(old?.downloadedBytes ?? 0, row.downloadedBytes),
                sampleCount: try ClashUsageBreakdown.add(old?.sampleCount ?? 0, row.sampleCount), clashSourceID: row.clashSourceID)
        }
        return Array(grouped.values)
    }
}
