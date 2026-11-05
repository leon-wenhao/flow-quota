import Foundation
import FlowQuotaCore

/// Validates the transport contract again and compares retries at persisted
/// millisecond precision. Scheduling belongs exclusively to the ACK operation.
enum TrafficAlertRecord {
    static let columns = """
        id, day, kind, source_key, source_name, observed_bytes, threshold_bytes,
        window_seconds, observed_seconds, policy_version, occurred_at_ms, scheduled_at_ms
        """

    static func milliseconds(_ date: Date) throws -> Int64 {
        let value = (date.timeIntervalSince1970 * 1_000).rounded()
        guard value.isFinite, value >= 1, value <= 253_402_300_799_999 else {
            throw TrafficAlertError.invalidEvent
        }
        return Int64(value)
    }

    static func identifier(_ value: String) throws -> String {
        guard let uuid = UUID(uuidString: value) else { throw TrafficAlertError.invalidEvent }
        return uuid.uuidString
    }

    static func validate(_ event: TrafficAlertEvent) throws {
        try event.validate()
        if event.kind == .applicationBurst, !AppKey.isCanonical(event.sourceKey) {
            throw TrafficAlertError.invalidEvent
        }
        guard event.sourceName.utf8.count <= 256, event.sourceKey.utf8.count <= 2048 else {
            throw TrafficAlertError.invalidEvent
        }
        let occurred = try milliseconds(event.occurredAt)
        if let scheduled = event.scheduledAt, try milliseconds(scheduled) < occurred {
            throw TrafficAlertError.invalidEvent
        }
    }

    static func matchesPolicy(_ event: TrafficAlertEvent, _ policy: TrafficAlertPolicy) -> Bool {
        policy.version == event.policyVersion && policy.threshold(for: event.kind) == event.thresholdBytes
            && (event.kind == .dailyInterface || policy.windowSeconds == event.windowSeconds)
    }

    static func samePayload(_ stored: TrafficAlertEvent, _ event: TrafficAlertEvent) throws -> Bool {
        let scheduled = try event.scheduledAt.map(milliseconds)
        let previousScheduled = try stored.scheduledAt.map(milliseconds)
        return try stored.day == event.day && stored.kind == event.kind
            && stored.sourceKey.utf8.elementsEqual(event.sourceKey.utf8)
            && stored.sourceName.utf8.elementsEqual(event.sourceName.utf8)
            && stored.observedBytes == event.observedBytes && stored.thresholdBytes == event.thresholdBytes
            && stored.windowSeconds == event.windowSeconds && stored.observedSeconds == event.observedSeconds
            && stored.policyVersion == event.policyVersion
            && milliseconds(stored.occurredAt) == milliseconds(event.occurredAt)
            && (scheduled == nil || scheduled == previousScheduled)
    }

    static func bindings(_ event: TrafficAlertEvent) throws -> [SQLValue] {
        [.text(try identifier(event.id)), .text(event.day), .text(event.kind.rawValue),
         .text(event.sourceKey), .text(event.sourceName), .integer(event.observedBytes), .integer(event.thresholdBytes),
         .integer(Int64(event.windowSeconds)), .integer(Int64(event.observedSeconds)), .integer(event.policyVersion),
         .integer(try milliseconds(event.occurredAt)), .null]
    }

    static func read(_ row: SQLiteStatement) throws -> TrafficAlertEvent {
        guard let kind = TrafficAlertKind(rawValue: row.text(2)) else { throw TrafficAlertError.invalidEvent }
        let event = TrafficAlertEvent(id: row.text(0), day: row.text(1), kind: kind,
            sourceKey: row.text(3), sourceName: row.text(4), observedBytes: row.integer(5),
            thresholdBytes: row.integer(6), windowSeconds: Int(row.integer(7)), observedSeconds: Int(row.integer(8)),
            policyVersion: row.integer(9), occurredAt: date(row.integer(10)),
            scheduledAt: row.optionalInteger(11).map(date))
        try event.validate()
        if kind == .applicationBurst, !AppKey.isCanonical(event.sourceKey) { throw TrafficAlertError.invalidEvent }
        return event
    }

    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}
