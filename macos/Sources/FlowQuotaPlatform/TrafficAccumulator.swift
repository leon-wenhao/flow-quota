import Foundation
import FlowQuotaCore

public struct ObservedIncrement: Sendable, Equatable {
    public let identity: AppIdentity
    public let uploadedBytes: Int64
    public let downloadedBytes: Int64
}

public struct TrafficAccumulation: Sendable {
    public let increments: [ObservedIncrement]
    public let rebaselined: Bool
    public let resetProcesses: Int
    /// Canonical app identities with at least one counter rollback in this frame.
    public let resetSourceKeys: Set<String>
    /// Sources with at least one measured process delta, distinct from baseline zeros.
    public let observedSourceKeys: Set<String>
}

/// Ephemeral baselines deliberately cannot reconstruct traffic before observation.
/// Missing processes are forgotten: a later reappearance starts with zero known delta.
public struct TrafficAccumulator: Sendable {
    private var previous: [String: ResolvedProcessCounter] = [:]
    private var scope: String?
    private var lastUptime: UInt64?
    private var lastSequence: UInt64?
    private var lastCapturedAt: Date?

    public init() {}

    public mutating func reset() {
        previous = [:]
        scope = nil
        lastUptime = nil
        lastSequence = nil
        lastCapturedAt = nil
    }

    public mutating func consume(_ counters: [ResolvedProcessCounter], scope: String,
                                 sequence: UInt64, uptime: UInt64, countTraffic: Bool,
                                 capturedAt: Date = Date()) throws -> TrafficAccumulation {
        let elapsed = lastUptime.flatMap { uptime >= $0 ? uptime - $0 : nil }
        let contiguous = lastSequence.map { sequence == $0 + 1 } ?? false
        let validBaseline = self.scope == scope && contiguous && elapsed.map { $0 <= 8_000_000_000 } == true
        var current: [String: ResolvedProcessCounter] = [:]
        var increments: [String: ObservedIncrement] = [:]
        var resets = 0
        var resetSources = Set<String>()
        var observedSources = Set<String>()
        for row in counters {
            guard row.uploadedBytes >= 0, row.downloadedBytes >= 0,
                  current.updateValue(row, forKey: row.processKey) == nil else {
                throw PlatformError.unavailable("采样进程计数无效或重复。")
            }
            var upload: Int64 = 0
            var download: Int64 = 0
            if countTraffic, validBaseline, let old = previous[row.processKey] {
                if old.uploadedBytes <= row.uploadedBytes && old.downloadedBytes <= row.downloadedBytes {
                    observedSources.insert(row.identity.key)
                    upload = row.uploadedBytes - old.uploadedBytes
                    download = row.downloadedBytes - old.downloadedBytes
                } else {
                    resets += 1
                    resetSources.insert(row.identity.key)
                }
            } else if countTraffic, validBaseline, let birth = row.startedAt,
                      let lastCapturedAt, birth > lastCapturedAt, birth <= capturedAt {
                // A process proven born inside this continuous observed interval has
                // no pre-observation bytes. Count its first burst instead of losing it.
                observedSources.insert(row.identity.key)
                upload = row.uploadedBytes
                download = row.downloadedBytes
            }
            let prior = increments[row.identity.key]
            let (up, upOverflow) = (prior?.uploadedBytes ?? 0).addingReportingOverflow(upload)
            let (down, downOverflow) = (prior?.downloadedBytes ?? 0).addingReportingOverflow(download)
            let (_, totalOverflow) = up.addingReportingOverflow(down)
            guard !upOverflow, !downOverflow, !totalOverflow else {
                throw PlatformError.unavailable("采样流量超出整数范围，已停止本批次入账。")
            }
            increments[row.identity.key] = ObservedIncrement(identity: row.identity,
                                                            uploadedBytes: up, downloadedBytes: down)
        }
        previous = current
        self.scope = scope
        lastSequence = sequence
        lastUptime = uptime
        lastCapturedAt = capturedAt
        return TrafficAccumulation(increments: increments.values.sorted { $0.identity.key < $1.identity.key },
                                   rebaselined: !validBaseline, resetProcesses: resets, resetSourceKeys: resetSources, observedSourceKeys: observedSources)
    }
}
