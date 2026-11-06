import Foundation

/// Immutable nettop attribution at an alert, separate from the physical meter.
public struct TrafficAlertApplication: Codable, Sendable, Equatable, Identifiable {
    public let identity: AppIdentity
    public let uploadedBytes: Int64
    public let downloadedBytes: Int64
    public let clashSources: [ClashUsageSource]?
    public var id: String { identity.key }
    public var totalBytes: Int64 {
        let (total, overflow) = uploadedBytes.addingReportingOverflow(downloadedBytes)
        return overflow ? .max : total
    }
    public var displayName: String { SystemProcessClassification(identity: identity).displayName }

    public init(identity: AppIdentity, uploadedBytes: Int64, downloadedBytes: Int64, clashSources: [ClashUsageSource]? = nil) {
        self.clashSources = clashSources
        self.identity = identity
        self.uploadedBytes = uploadedBytes
        self.downloadedBytes = downloadedBytes
    }

    public var displaySources: [ClashUsageSource] {
        if ClashUsageBreakdown.isProxy(identity) {
            return clashSources ?? [ClashUsageBreakdown.unknown(upload: uploadedBytes, download: downloadedBytes)]
        }
        return [ClashUsageSource(id: "app:" + id, name: displayName, uploadedBytes: uploadedBytes, downloadedBytes: downloadedBytes)]
    }

    public func validate() throws {
        if let clashSources {
            guard ClashUsageBreakdown.isProxy(identity), !clashSources.isEmpty, clashSources.count <= 129,
                  Set(clashSources.map(\.id)).count == clashSources.count else { throw TrafficAlertError.invalidEvent }
            for source in clashSources { try source.validate() }
            guard try clashSources.reduce(Int64(0), { try ClashUsageBreakdown.add($0, $1.uploadedBytes) }) == uploadedBytes,
                  try clashSources.reduce(Int64(0), { try ClashUsageBreakdown.add($0, $1.downloadedBytes) }) == downloadedBytes else {
                throw TrafficAlertError.invalidEvent
            }
        }
        guard AppKey.isCanonical(identity.key), identity.key.utf8.count <= 2048,
              !identity.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              identity.name.utf8.count <= 256, !identity.name.contains("\0"),
              uploadedBytes >= 0, downloadedBytes >= 0,
              !uploadedBytes.addingReportingOverflow(downloadedBytes).overflow else {
            throw TrafficAlertError.invalidEvent
        }
    }
}

public struct TrafficAlertApplications: Codable, Sendable, Equatable {
    public let items: [TrafficAlertApplication]
    public let observedAt: Date?
    public let omittedCount: Int
    public let notice: String?

    public init(items: [TrafficAlertApplication], observedAt: Date?, omittedCount: Int = 0, notice: String? = nil) {
        self.items = items.sorted {
            $0.totalBytes == $1.totalBytes ? $0.id < $1.id : $0.totalBytes > $1.totalBytes
        }
        self.observedAt = observedAt
        self.omittedCount = omittedCount
        self.notice = notice
    }

    public var displaySources: [ClashUsageSource] {
        items.flatMap(\.displaySources).sorted {
            let a = $0.totalBytes ?? .max
            let b = $1.totalBytes ?? .max
            return a == b ? $0.id < $1.id : a > b
        }
    }

    /// Freeze display children without changing the canonical triggering identity.
    /// Multiple proxy identities cannot share the same child evidence safely.
    public func resolvingClash(_ sources: [ClashUsageSource]) -> Self {
        let parents = items.filter { ClashUsageBreakdown.isProxy($0.identity) }
        let mapped = items.map { item -> TrafficAlertApplication in
            guard ClashUsageBreakdown.isProxy(item.identity) else { return item }
            let result = try? ClashUsageBreakdown.split(upload: item.uploadedBytes, download: item.downloadedBytes,
                sources: parents.count == 1 ? sources : [])
            return TrafficAlertApplication(identity: item.identity, uploadedBytes: item.uploadedBytes,
                downloadedBytes: item.downloadedBytes, clashSources: result?.sources
                    ?? [ClashUsageBreakdown.unknown(upload: item.uploadedBytes, download: item.downloadedBytes)])
        }
        return Self(items: mapped, observedAt: observedAt, omittedCount: omittedCount, notice: notice)
    }

    public static func unavailable(_ reason: String) -> Self {
        Self(items: [], observedAt: nil, notice: bounded(reason, bytes: 512))
    }

    /// Polling transports only a bounded name summary. Full identities/directions
    /// are fetched for one expanded event, keeping the existing 1 MiB XPC limit.
    public var summary: String {
        guard !items.isEmpty else { return observedAt == nil ? "应用明细暂不可用" : "未观测到应用正用量" }
        let names = displaySources.prefix(3).map(\.name).joined(separator: "、")
        let count = displaySources.count + omittedCount
        return Self.bounded(names, bytes: 220) + (count > 3 ? " 等 \(count) 项" : "")
    }

    public func validate() throws {
        guard items.count <= 128, omittedCount >= 0, omittedCount <= 1_000_000,
              Set(items.map(\.id)).count == items.count,
              notice.map({ $0.utf8.count <= 512 && !$0.contains("\0") }) ?? true,
              observedAt != nil || (items.isEmpty && notice != nil),
              observedAt.map({ $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 > 0
                  && $0.timeIntervalSince1970 < 253_402_300_800 }) ?? true else {
            throw TrafficAlertError.invalidEvent
        }
        for item in items { try item.validate() }
        guard try JSONEncoder().encode(self).count <= 524288 else { throw TrafficAlertError.invalidEvent }
    }

    public static func bounded(_ text: String, bytes: Int) -> String {
        var result = ""
        for character in text {
            guard result.utf8.count + String(character).utf8.count <= bytes else { break }
            result.append(character)
        }
        return result
    }
}
