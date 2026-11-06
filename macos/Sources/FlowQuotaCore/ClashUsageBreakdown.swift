import Foundation

/// A bounded display source, never an application identity or quota ledger entry.
/// `identified` is persisted explicitly; a lost domain/path must not turn unknown
/// connections into named traffic when the service restarts.
public struct ClashUsageSource: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let uploadedBytes: Int64
    public let downloadedBytes: Int64
    public let identified: Bool

    public init(id: String, name: String, uploadedBytes: Int64, downloadedBytes: Int64, identified: Bool = true) {
        self.id = id
        self.name = name
        self.uploadedBytes = uploadedBytes
        self.downloadedBytes = downloadedBytes
        self.identified = identified
    }

    public func validate() throws {
        guard !id.isEmpty, id.utf8.count <= 8192, !id.contains("\0"),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 512, !name.contains("\0"),
              uploadedBytes >= 0, downloadedBytes >= 0 else { throw ClashBreakdownError.invalid }
        _ = try ClashUsageBreakdown.add(uploadedBytes, downloadedBytes)
    }

    public var totalBytes: Int64? {
        guard uploadedBytes >= 0, downloadedBytes >= 0 else { return nil }
        let (sum, overflow) = uploadedBytes.addingReportingOverflow(downloadedBytes)
        return overflow ? nil : sum
    }

    public var proxySource: MihomoProxySource {
        MihomoProxySource(id: id, displayName: name, connectionCount: 0,
            uploadedBytes: uploadedBytes, downloadedBytes: downloadedBytes)
    }
}

public struct ClashMinuteUsage: Sendable, Equatable {
    public let minute: Int64
    public let source: ClashUsageSource
    public init(minute: Int64, source: ClashUsageSource) { self.minute = minute; self.source = source }
}

public struct ClashUsageBreakdown: Codable, Sendable, Equatable {
    public static let unknownID = "unidentified"
    public let sources: [ClashUsageSource]
    /// Raw evidence remains available in measurement details when matching fails.
    public let notice: String?

    public init(sources: [ClashUsageSource], notice: String? = nil) {
        self.sources = sources
        self.notice = notice
    }

    public static func isProxy(_ identity: AppIdentity) -> Bool {
        SystemProcessClassification(identity: identity).category == .sharedProxy
    }

    /// The two directions are checked independently. An invalid/over-budget
    /// interval becomes wholly unknown, never scaled or borrowed from another minute.
    public static func split(upload: Int64, download: Int64, sources: [ClashUsageSource]) throws -> Self {
        guard upload >= 0, download >= 0 else { throw ClashBreakdownError.invalid }
        _ = try add(upload, download)
        do {
            var named: [String: ClashUsageSource] = [:]
            for source in sources {
                try source.validate()
                guard source.identified else { continue }
                guard source.id != unknownID else { throw ClashBreakdownError.invalid }
                let old = named[source.id]
                guard old == nil || old?.name == source.name else { throw ClashBreakdownError.invalid }
                named[source.id] = ClashUsageSource(id: source.id, name: source.name,
                    uploadedBytes: try add(old?.uploadedBytes ?? 0, source.uploadedBytes),
                    downloadedBytes: try add(old?.downloadedBytes ?? 0, source.downloadedBytes))
            }
            let usedUpload = try named.values.reduce(Int64(0)) { try add($0, $1.uploadedBytes) }
            let usedDownload = try named.values.reduce(Int64(0)) { try add($0, $1.downloadedBytes) }
            guard usedUpload <= upload, usedDownload <= download else { throw ClashBreakdownError.invalid }
            var result = Array(named.values).filter { $0.uploadedBytes > 0 || $0.downloadedBytes > 0 }
            if upload > usedUpload || download > usedDownload || result.isEmpty {
                result.append(unknown(upload: upload - usedUpload, download: download - usedDownload))
            }
            return Self(sources: sorted(result), notice: nil)
        } catch {
            return Self(sources: [unknown(upload: upload, download: download)],
                notice: "部分 Clash 来源与对应分钟内核计数无法核对，该分钟完整保留为其他未识别。原始证据见计量详情。")
        }
    }

    public static func unknown(upload: Int64, download: Int64) -> ClashUsageSource {
        ClashUsageSource(id: unknownID, name: "其他未识别（Clash）", uploadedBytes: upload,
                         downloadedBytes: download, identified: false)
    }

    public static func aggregate(_ sources: [ClashUsageSource]) throws -> [ClashUsageSource] {
        var result: [String: ClashUsageSource] = [:]
        for source in sources {
            try source.validate()
            let old = result[source.id]
            guard old == nil || (old?.name == source.name && old?.identified == source.identified) else {
                throw ClashBreakdownError.invalid
            }
            let next = ClashUsageSource(id: source.id, name: source.name,
                uploadedBytes: try add(old?.uploadedBytes ?? 0, source.uploadedBytes),
                downloadedBytes: try add(old?.downloadedBytes ?? 0, source.downloadedBytes), identified: source.identified)
            try next.validate()
            result[source.id] = next
        }
        return sorted(Array(result.values))
    }

    public static func add(_ a: Int64, _ b: Int64) throws -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        guard a >= 0, b >= 0, !overflow else { throw ClashBreakdownError.invalid }
        return sum
    }

    private static func sorted(_ sources: [ClashUsageSource]) -> [ClashUsageSource] {
        sources.sorted {
            let left = $0.totalBytes ?? .max
            let right = $1.totalBytes ?? .max
            return left == right ? $0.id < $1.id : left > right
        }
    }
}

public enum ClashBreakdownError: Error { case invalid }
