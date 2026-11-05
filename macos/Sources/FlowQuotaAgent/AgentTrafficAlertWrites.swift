import Foundation
import FlowQuotaCore

/// A bounded retry buffer, not a second ledger. Retain the first earned event/UUID
/// per kind + source until storage admits or suppresses it. No samples are queued.
struct TrafficAlertWriteBuffer: Sendable {
    private var events: [String: TrafficAlertEvent] = [:]
    var count: Int { events.count }

    mutating func retain(day: String, policy: TrafficAlertPolicy) {
        events = events.filter {
            $0.value.day == day && $0.value.policyVersion == policy.version
                && policy.threshold(for: $0.value.kind) == $0.value.thresholdBytes
        }
    }

    /// Two interface kinds + at most 128 app identities, one candidate per key.
    mutating func stage(_ event: TrafficAlertEvent) throws {
        let key = event.kind.rawValue + ":" + event.sourceKey
        guard events[key] == nil else { return }
        if event.kind == .applicationBurst,
           events.values.filter({ $0.kind == .applicationBurst }).count >= 128 {
            throw TrafficAlertError.pendingEventLimit
        }
        events[key] = event
    }

    func candidates(kind: TrafficAlertKind) -> [TrafficAlertEvent] {
        events.values.filter { $0.kind == kind }.sorted { $0.sourceKey < $1.sourceKey }
    }

    mutating func remove(_ event: TrafficAlertEvent) {
        let key = event.kind.rawValue + ":" + event.sourceKey
        // A suspended write must never erase a replacement from a newer policy.
        if events[key]?.id == event.id { events.removeValue(forKey: key) }
    }
}

extension AgentRuntime {
    func trafficAlertsAreCurrent(generation: UInt64, epoch: UInt64) -> Bool {
        generation == samplingGeneration && epoch == trafficAlertEpoch
    }

    /// A failed INSERT retains its original time/payload/UUID, even when its window
    /// later slides out. Durable store dedup covers a retry after an uncertain ACK.
    /// Failure for one app must not skip the remaining apps. Policy/day changes
    /// prune obsolete candidates before this method is called.
    func flushTrafficAlertWrites(kind: TrafficAlertKind, generation: UInt64, epoch: UInt64) async -> String? {
        var failure: String?
        for event in trafficAlertWrites.candidates(kind: kind) {
            guard trafficAlertsAreCurrent(generation: generation, epoch: epoch) else { return failure }
            do {
                _ = try await store.recordTrafficAlert(event)
                trafficAlertWrites.remove(event)
            } catch {
                if failure == nil { failure = error.localizedDescription }
            }
        }
        return failure
    }
}
