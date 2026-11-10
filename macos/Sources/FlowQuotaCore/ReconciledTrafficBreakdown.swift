import Foundation

/// A source after reconciling process evidence against the physical interface meter.
/// These rows are display evidence only; application rules and alerts continue to
/// use the raw canonical process ledger.
public enum ReconciledTrafficSourceKind: String, Codable, Sendable {
    case application
    case clash
    case unidentified
}

public struct ReconciledTrafficSource: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let kind: ReconciledTrafficSourceKind
    public let appKey: String?
    public let uploadedBytes: Int64
    public let downloadedBytes: Int64

    public init(id: String, name: String, kind: ReconciledTrafficSourceKind,
                appKey: String? = nil, uploadedBytes: Int64, downloadedBytes: Int64) {
        self.id = id
        self.name = name
        self.kind = kind
        self.appKey = appKey
        self.uploadedBytes = uploadedBytes
        self.downloadedBytes = downloadedBytes
    }

    public var totalBytes: Int64? {
        guard uploadedBytes >= 0, downloadedBytes >= 0 else { return nil }
        let (total, overflow) = uploadedBytes.addingReportingOverflow(downloadedBytes)
        return overflow ? nil : total
    }
}

public struct ReconciledTrafficMinuteResult: Sendable, Equatable {
    public let rows: [ApplicationUsageBucket]
    public let notice: String?

    public init(rows: [ApplicationUsageBucket], notice: String?) {
        self.rows = rows
        self.notice = notice
    }
}

public struct ReconciledTrafficBreakdown: Codable, Sendable, Equatable {
    public static let unidentifiedID = "interface-unidentified"
    public static let unidentifiedName = "其他未识别"

    public let sources: [ReconciledTrafficSource]
    public let notice: String?

    public init(sources: [ReconciledTrafficSource], notice: String? = nil) {
        self.sources = sources
        self.notice = notice
    }

    /// Resolves each minute independently. A source overage in either direction
    /// invalidates the whole minute, preserving the physical parent as unknown.
    public static func resolve(interfaceMinutes: [InterfaceUsageMinute],
                               processMinutes: [ApplicationUsageBucket],
                               clashMinutes: [ClashMinuteUsage]) throws -> Self {
        let result = try resolveMinutes(interfaceMinutes: interfaceMinutes,
            processMinutes: processMinutes, clashMinutes: clashMinutes)
        var aggregate: [String: ReconciledTrafficSource] = [:]
        for row in result.rows {
            try append(&aggregate, source(from: row))
        }
        return Self(sources: sorted(Array(aggregate.values)), notice: result.notice)
    }

    public static func resolveMinutes(interfaceMinutes: [InterfaceUsageMinute],
                                      processMinutes: [ApplicationUsageBucket],
                                      clashMinutes: [ClashMinuteUsage]) throws -> ReconciledTrafficMinuteResult {
        let interfaces = try validatedInterfaces(interfaceMinutes)
        let clashResult = try ClashMinuteBreakdown.resolve(processes: processMinutes, sources: clashMinutes)
        let resolved = clashResult.rows
        var rowsByMinute: [Int64: [ApplicationUsageBucket]] = [:]
        for row in resolved {
            guard row.startMilliseconds % 60_000 == 0, row.uploadedBytes >= 0,
                  row.downloadedBytes >= 0, row.sampleCount > 0,
                  !row.uploadedBytes.addingReportingOverflow(row.downloadedBytes).overflow else {
                throw BreakdownError.invalid
            }
            rowsByMinute[row.startMilliseconds, default: []].append(row)
        }

        var output: [ApplicationUsageBucket] = []
        var conflictCount = 0
        var unknownMinutes = 0
        var notices: [String] = []
        if let notice = clashResult.notice { notices.append(notice) }
        var orphanSourceMinutes = Set(rowsByMinute.keys)
        for parent in interfaces {
            orphanSourceMinutes.remove(parent.minuteStartMilliseconds)
            let rows = rowsByMinute[parent.minuteStartMilliseconds] ?? []
            let sources = try mergeSources(rows)
            let usedUpload = try sources.reduce(Int64(0)) { try add($0, $1.uploadedBytes) }
            let usedDownload = try sources.reduce(Int64(0)) { try add($0, $1.downloadedBytes) }
            guard usedUpload <= parent.uploadedBytes && usedDownload <= parent.downloadedBytes else {
                conflictCount += 1
                output.append(unknownRow(minute: parent.minuteStartMilliseconds,
                    upload: parent.uploadedBytes, download: parent.downloadedBytes))
                continue
            }
            output += sources.compactMap { source in
                guard source.uploadedBytes > 0 || source.downloadedBytes > 0 else { return nil }
                return row(from: source, minute: parent.minuteStartMilliseconds)
            }
            let remainderUpload = parent.uploadedBytes - usedUpload
            let remainderDownload = parent.downloadedBytes - usedDownload
            if remainderUpload > 0 || remainderDownload > 0 || sources.isEmpty {
                unknownMinutes += 1
                output.append(unknownRow(minute: parent.minuteStartMilliseconds,
                    upload: remainderUpload, download: remainderDownload))
            }
        }

        notices += [
            conflictCount > 0 ? "有\(conflictCount)个分钟的来源超过接口父项或发生方向冲突，已整分钟保留为其他未识别。" : nil,
            unknownMinutes > 0 ? "有\(unknownMinutes)个分钟存在未能可靠归属的接口余量。" : nil,
            orphanSourceMinutes.isEmpty ? nil : "有\(orphanSourceMinutes.count)个分钟只有进程证据而没有对应接口父项，原始证据保留在计量详情。"
        ].compactMap { $0 }
        return ReconciledTrafficMinuteResult(rows: output.sorted { $0.id < $1.id },
            notice: notices.isEmpty ? nil : notices.joined(separator: " "))
    }

    public static func unknown(upload: Int64, download: Int64) -> ReconciledTrafficSource {
        ReconciledTrafficSource(id: unidentifiedID, name: unidentifiedName, kind: .unidentified,
            uploadedBytes: upload, downloadedBytes: download)
    }

    private static func validatedInterfaces(_ rows: [InterfaceUsageMinute]) throws -> [InterfaceUsageMinute] {
        var seen = Set<Int64>()
        for row in rows {
            guard row.minuteStartMilliseconds % 60_000 == 0, row.sampleCount > 0,
                  row.uploadedBytes >= 0, row.downloadedBytes >= 0,
                  !row.uploadedBytes.addingReportingOverflow(row.downloadedBytes).overflow,
                  seen.insert(row.minuteStartMilliseconds).inserted else { throw BreakdownError.invalid }
        }
        return rows.sorted { $0.minuteStartMilliseconds < $1.minuteStartMilliseconds }
    }

    private static func mergeSources(_ rows: [ApplicationUsageBucket]) throws -> [ReconciledTrafficSource] {
        var result: [String: ReconciledTrafficSource] = [:]
        for row in rows { try append(&result, source(from: row)) }
        return Array(result.values)
    }

    private static func source(from row: ApplicationUsageBucket) throws -> ReconciledTrafficSource {
        guard row.uploadedBytes >= 0, row.downloadedBytes >= 0 else { throw BreakdownError.invalid }
        if let clashID = row.clashSourceID {
            let kind: ReconciledTrafficSourceKind = clashID == ClashUsageBreakdown.unknownID || clashID == unidentifiedID ? .unidentified : .clash
            return ReconciledTrafficSource(id: "clash:" + clashID, name: row.name, kind: kind,
                uploadedBytes: row.uploadedBytes, downloadedBytes: row.downloadedBytes)
        }
        guard let appKey = row.appKey else { throw BreakdownError.invalid }
        let displayName = SystemProcessClassification(identity: AppIdentity(key: appKey, name: row.name)).displayName
        return ReconciledTrafficSource(id: "application:" + appKey, name: displayName,
            kind: .application, appKey: appKey, uploadedBytes: row.uploadedBytes,
            downloadedBytes: row.downloadedBytes)
    }

    private static func row(from source: ReconciledTrafficSource, minute: Int64) -> ApplicationUsageBucket {
        switch source.kind {
        case .application:
            return ApplicationUsageBucket(appKey: source.appKey, name: source.name, startMilliseconds: minute,
                uploadedBytes: source.uploadedBytes, downloadedBytes: source.downloadedBytes, sampleCount: 1)
        case .clash:
            let id = source.id.hasPrefix("clash:") ? String(source.id.dropFirst("clash:".count)) : source.id
            return ApplicationUsageBucket(appKey: nil, name: source.name, startMilliseconds: minute,
                uploadedBytes: source.uploadedBytes, downloadedBytes: source.downloadedBytes, sampleCount: 1,
                clashSourceID: id)
        case .unidentified:
            return unknownRow(minute: minute, upload: source.uploadedBytes, download: source.downloadedBytes)
        }
    }

    private static func unknownRow(minute: Int64, upload: Int64, download: Int64) -> ApplicationUsageBucket {
        ApplicationUsageBucket(appKey: nil, name: unidentifiedName, startMilliseconds: minute,
            uploadedBytes: upload, downloadedBytes: download, sampleCount: 1,
            clashSourceID: unidentifiedID)
    }

    private static func append(_ result: inout [String: ReconciledTrafficSource],
                               _ source: ReconciledTrafficSource) throws {
        guard source.uploadedBytes >= 0, source.downloadedBytes >= 0 else { throw BreakdownError.invalid }
        if let old = result[source.id] {
            guard old.name == source.name, old.kind == source.kind, old.appKey == source.appKey else {
                throw BreakdownError.invalid
            }
            result[source.id] = ReconciledTrafficSource(id: old.id, name: old.name, kind: old.kind,
                appKey: old.appKey, uploadedBytes: try add(old.uploadedBytes, source.uploadedBytes),
                downloadedBytes: try add(old.downloadedBytes, source.downloadedBytes))
        } else {
            result[source.id] = source
        }
    }

    private static func add(_ left: Int64, _ right: Int64) throws -> Int64 {
        guard left >= 0, right >= 0 else { throw BreakdownError.invalid }
        let (sum, overflow) = left.addingReportingOverflow(right)
        guard !overflow else { throw BreakdownError.invalid }
        return sum
    }

    private static func sorted(_ sources: [ReconciledTrafficSource]) -> [ReconciledTrafficSource] {
        sources.sorted {
            let left = $0.totalBytes ?? -1
            let right = $1.totalBytes ?? -1
            return left == right ? $0.id < $1.id : left > right
        }
    }

    private enum BreakdownError: Error { case invalid }
}
