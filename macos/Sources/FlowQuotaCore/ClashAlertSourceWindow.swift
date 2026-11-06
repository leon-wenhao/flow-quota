import Foundation

/// API source evidence for alerts. No wall-clock minute reconstruction: only
/// complete monotonic intervals contained in the triggering window may contribute.
public struct ClashAlertSourceWindow: Sendable {
    private struct Bucket: Sendable {
        let start: UInt64
        let end: UInt64
        let sources: [ClashUsageSource]
    }
    private var buckets: [Bucket] = []
    private var scope: String?
    public init() {}
    public mutating func reset() { self = Self() }

    public mutating func consume(_ sources: [ClashUsageSource], start: UInt64?, end: UInt64,
                                 scope: String, windowSeconds: Int) throws {
        guard (60...900).contains(windowSeconds) else { reset(); throw TrafficAlertError.invalidPolicy }
        guard let start, start < end, end - start <= 8_000_000_000 else { reset(); return }
        if self.scope != scope || buckets.last.map({ $0.end != start }) == true {
            reset()
            self.scope = scope
            return
        }
        self.scope = scope
        let span = UInt64(windowSeconds) * 1_000_000_000
        let cutoff = end > span ? end - span : 0
        buckets.removeAll { $0.start < cutoff }
        do {
            for source in sources { try source.validate() }
            let ids = Set(buckets.flatMap { $0.sources.map(\.id) }).union(sources.map(\.id))
            guard (60...900).contains(windowSeconds), ids.count <= 128 else { throw TrafficAlertError.sourceLimit }
            guard buckets.count < 450 else { throw TrafficAlertError.bucketLimit }
            // Catch cumulative overflow now, while the caller can expose the failure.
            _ = try ClashUsageBreakdown.aggregate(buckets.flatMap(\.sources) + sources)
            buckets.append(Bucket(start: start, end: end, sources: sources))
        } catch { reset(); throw error }
    }

    public func sources(since start: UInt64, through end: UInt64, scope: String) -> [ClashUsageSource] {
        guard self.scope == scope, start <= end else { return [] }
        let contained = buckets.filter { $0.start >= start && $0.end <= end }
        return (try? ClashUsageBreakdown.aggregate(contained.flatMap(\.sources))) ?? []
    }
}
