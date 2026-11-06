import Foundation

/// Caller serializes one instance per meter. Only fully contained delta buckets
/// count; partial left-edge buckets are discarded rather than guessed/prorated.
/// At most 450 buckets and 128 distinct sources, independent of frame input size.
public struct TrafficAlertWindow: Sendable {
    private struct Bucket: Sendable {
        let start: UInt64
        var bytes: [String: Int64]
    }
    private var buckets: [Bucket] = []
    private var previous: UInt64?
    private var scope: String?
    /// A valid baseline alone is not a measured interval or recovered coverage.
    public private(set) var isCollecting = false
    public init() {}
    public mutating func reset() {
        buckets = []; previous = nil; scope = nil; isCollecting = false
    }

    /// resetSources discards only those apps' history and current frame. A rollback
    /// in one helper conservatively rebases its app, without erasing other apps.
    public mutating func consume(_ bytes: [String: Int64], uptime: UInt64, scope: String,
                                 windowSeconds: Int, continuous: Bool,
                                 resetSources: Set<String> = []) throws -> [String: WindowUsage] {
        guard (60...900).contains(windowSeconds), bytes.values.allSatisfy({ $0 >= 0 }) else {
            reset(); throw TrafficAlertError.invalidPolicy
        }
        // Check baseline frames as well: continuous over-capacity input must never
        // alternate between a failure and an apparently healthy empty baseline.
        guard bytes.count <= 128 else { reset(); throw TrafficAlertError.sourceLimit }
        let old = previous
        if !continuous || self.scope != scope || old == nil || uptime <= old!
            || uptime - old! > 8_000_000_000 {
            reset(); self.scope = scope; previous = uptime; return [:]
        }
        previous = uptime
        let span = UInt64(windowSeconds) * 1_000_000_000
        let cutoff = uptime > span ? uptime - span : 0
        buckets.removeAll { $0.start < cutoff }
        if !resetSources.isEmpty {
            for index in buckets.indices {
                buckets[index].bytes = buckets[index].bytes.filter { !resetSources.contains($0.key) }
            }
        }
        let current = bytes.filter { !resetSources.contains($0.key) }
        let sources = Set(buckets.flatMap { $0.bytes.keys }).union(current.keys)
        guard sources.count <= 128 else { reset(); throw TrafficAlertError.sourceLimit }
        guard buckets.count < 450 else { reset(); throw TrafficAlertError.bucketLimit }
        buckets.append(Bucket(start: old!, bytes: current))
        var totals: [String: WindowUsage] = [:]
        for bucket in buckets {
            for (key, value) in bucket.bytes {
                let (sum, overflow) = (totals[key]?.bytes ?? 0).addingReportingOverflow(value)
                guard !overflow else { reset(); throw TrafficAlertError.overflow }
                // After a per-source reset, its observed interval starts with its
                // first retained bucket, rather than borrowing another app's age.
                let seconds = max(1, Int((uptime - bucket.start) / 1_000_000_000))
                totals[key] = WindowUsage(bytes: sum, observedSeconds: totals[key]?.observedSeconds
                    ?? min(seconds, windowSeconds),
                    startedAt: totals[key]?.startedAt ?? bucket.start)
            }
        }
        isCollecting = true
        return totals
    }
}

public struct WindowUsage: Sendable, Equatable {
    public let bytes: Int64
    public let observedSeconds: Int
    public let startedAt: UInt64

    public init(bytes: Int64, observedSeconds: Int, startedAt: UInt64 = 0) {
        self.bytes = bytes
        self.observedSeconds = observedSeconds
        self.startedAt = startedAt
    }
}
