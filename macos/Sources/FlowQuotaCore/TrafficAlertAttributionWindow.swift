import Foundation

/// Directional evidence for interface/application alerts. The nettop source and
/// the physical meter run independently; only fully contained buckets are used.
public struct TrafficAlertAttributionWindow: Sendable {
    private struct Bucket: Sendable {
        let start: UInt64
        let end: UInt64
        let observedAt: Date
        let items: [String: TrafficAlertApplication]
    }
    private var buckets: [Bucket] = []
    private var previous: UInt64?
    private var scope: String?
    private var problem = "预警触发时尚未建立连续的应用观测。"
    public init() {}

    public mutating func reset() { self = Self() }

    public mutating func consume(_ items: [TrafficAlertApplication], uptime: UInt64, observedAt: Date,
                                 scope: String, windowSeconds: Int, continuous: Bool,
                                 resetSources: Set<String> = []) throws {
        do {
            var current: [String: TrafficAlertApplication] = [:]
            for item in items {
                try item.validate()
                let old = current[item.id]
                let (up, overflowUp) = (old?.uploadedBytes ?? 0).addingReportingOverflow(item.uploadedBytes)
                let (down, overflowDown) = (old?.downloadedBytes ?? 0).addingReportingOverflow(item.downloadedBytes)
                guard !overflowUp, !overflowDown, !up.addingReportingOverflow(down).overflow else {
                    throw TrafficAlertError.overflow
                }
                if up > 0 || down > 0 {
                    current[item.id] = TrafficAlertApplication(identity: item.identity, uploadedBytes: up, downloadedBytes: down)
                }
            }
            guard current.count <= 128 else { throw TrafficAlertError.sourceLimit }
            guard (60...900).contains(windowSeconds) else { throw TrafficAlertError.invalidPolicy }
            let old = previous
            if !continuous || self.scope != scope || old == nil || uptime <= old! || uptime - old! > 8_000_000_000 {
                reset()
                self.scope = scope
                previous = uptime
                return
            }
            let span = UInt64(windowSeconds) * 1_000_000_000
            let cutoff = uptime > span ? uptime - span : 0
            buckets.removeAll { $0.start < cutoff }
            if !resetSources.isEmpty {
                buckets = buckets.map { bucket in
                    Bucket(start: bucket.start, end: bucket.end, observedAt: bucket.observedAt,
                           items: bucket.items.filter { !resetSources.contains($0.key) })
                }
                current = current.filter { !resetSources.contains($0.key) }
            }
            let sources = Set(buckets.flatMap { $0.items.keys }).union(current.keys)
            guard sources.count <= 128 else { throw TrafficAlertError.sourceLimit }
            guard buckets.count < 450 else { throw TrafficAlertError.bucketLimit }
            buckets.append(Bucket(start: old!, end: uptime, observedAt: observedAt, items: current))
            previous = uptime
        } catch {
            reset()
            problem = "应用归因窗口不可用：\(error.localizedDescription)"
            throw error
        }
    }

    /// Never mutates the sampling baseline or borrows a later frame. A bucket
    /// straddling the interface interval is unknown, rather than prorated.
    public func snapshot(since start: UInt64, through end: UInt64, scope: String,
                         sourceKey: String? = nil) -> TrafficAlertApplications {
        guard self.scope == scope else { return .unavailable(problem) }
        let contained = buckets.filter { $0.start >= start && $0.end <= end }
        guard let last = contained.last, end - last.end <= 8_000_000_000 else {
            return .unavailable("预警时段内尚无完整的应用观测区间。")
        }
        do {
            var totals: [String: TrafficAlertApplication] = [:]
            for bucket in contained {
                for (key, item) in bucket.items where sourceKey == nil || sourceKey == key {
                    let old = totals[key]
                    let (up, overflowUp) = (old?.uploadedBytes ?? 0).addingReportingOverflow(item.uploadedBytes)
                    let (down, overflowDown) = (old?.downloadedBytes ?? 0).addingReportingOverflow(item.downloadedBytes)
                    guard !overflowUp, !overflowDown, !up.addingReportingOverflow(down).overflow else {
                        throw TrafficAlertError.overflow
                    }
                    totals[key] = TrafficAlertApplication(identity: item.identity, uploadedBytes: up, downloadedBytes: down)
                }
            }
            let snapshot = TrafficAlertApplications(items: Array(totals.values), observedAt: last.observedAt,
                notice: sourceKey == nil ? "仅列出预警窗口内完整观测的应用增量；应用与接口采样时间可能不同。" : nil)
            try snapshot.validate()
            return snapshot
        } catch { return .unavailable("应用归因合计或证据容量超限，无法展示明细。") }
    }
}
