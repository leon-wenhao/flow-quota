import Foundation
import FlowQuotaCore

extension QuotaStore {
    /// Returns true only for a new durable event. Exact UUID retries return false
    /// even after ACK; conflicting payloads throw. Stale/off rules are suppressed.
    public func recordTrafficAlert(_ event: TrafficAlertEvent) throws -> Bool {
        try TrafficAlertRecord.validate(event)
        let id = try TrafficAlertRecord.identifier(event.id)
        let occurred = try TrafficAlertRecord.milliseconds(event.occurredAt)
        return try database.transaction {
            let today = try StoreDay.label(at: clock(), calendar: calendar)
            guard event.day == today else { throw StoreError.inactiveDay }
            guard try StoreDay.label(at: event.occurredAt, calendar: calendar) == today else {
                throw TrafficAlertError.invalidEvent
            }
            if let previous = try trafficAlert(id: id) {
                guard try TrafficAlertRecord.samePayload(previous, event) else { throw StoreError.trafficAlertConflict }
                return false
            }
            // An exact replay of an acknowledged row is harmless, but callers
            // cannot import a scheduling timestamp into a new outbox event.
            guard event.scheduledAt == nil else { throw TrafficAlertError.invalidEvent }
            let policy = try trafficAlertPolicy()
            guard TrafficAlertRecord.matchesPolicy(event, policy) else { return false }
            // Do not bound this query by the proposed occurrence/cooldown: an
            // occurrence behind the persisted maximum must suppress after restart.
            let latest = try database.query("""
                SELECT MAX(occurred_at_ms) FROM traffic_alert_events
                WHERE day = ? AND kind = ? AND source_key = ? AND policy_version = ?
                """, [.text(today), .text(event.kind.rawValue), .text(event.sourceKey), .integer(event.policyVersion)]) {
                    $0.optionalInteger(0)
                }.first ?? nil
            if let latest {
                if event.kind == .dailyInterface { return false }
                guard occurred > latest, occurred - latest >= Int64(policy.cooldownSeconds) * 1_000 else { return false }
            }
            guard try database.scalar("SELECT COUNT(*) FROM traffic_alert_events WHERE day = ?", [.text(today)]) < 256 else {
                throw TrafficAlertError.eventLimit
            }
            try database.execute("""
                INSERT INTO traffic_alert_events (\(TrafficAlertRecord.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, try TrafficAlertRecord.bindings(event))
            return true
        }
    }

    /// At most 256 most recent events; UUID descending makes timestamp ties stable.
    public func trafficAlertEvents(day: String, limit: Int = 256, offset: Int = 0) throws -> [TrafficAlertEvent] {
        try StoreDay.validate(day)
        guard (1...256).contains(limit), (0...256).contains(offset) else { throw TrafficAlertError.invalidEvent }
        return try database.query("""
            SELECT \(TrafficAlertRecord.columns) FROM traffic_alert_events
            WHERE day = ? ORDER BY occurred_at_ms DESC, id DESC LIMIT ? OFFSET ?
            """, [.text(day), .integer(Int64(limit)), .integer(Int64(offset))], row: TrafficAlertRecord.read)
    }

    /// ACK means OS scheduling acceptance. The injected service clock determines
    /// both current day and timestamp; repeat ACKs never change the first stamp.
    public func acknowledgeTrafficAlert(id: String, day: String) throws {
        try StoreDay.validate(day)
        let id = try TrafficAlertRecord.identifier(id)
        try database.transaction {
            let now = clock()
            guard try StoreDay.label(at: now, calendar: calendar) == day else { throw StoreError.inactiveDay }
            guard let event = try trafficAlert(id: id), event.day == day else { throw StoreError.unknownTrafficAlert(id) }
            guard try TrafficAlertRecord.matchesPolicy(event, trafficAlertPolicy()) else { throw StoreError.staleTrafficAlertPolicy }
            if event.scheduledAt != nil { return }
            let scheduled = try TrafficAlertRecord.milliseconds(now)
            guard scheduled >= (try TrafficAlertRecord.milliseconds(event.occurredAt)) else { throw TrafficAlertError.invalidEvent }
            try database.execute("""
                UPDATE traffic_alert_events SET scheduled_at_ms = ? WHERE id = ? AND day = ? AND scheduled_at_ms IS NULL
                """, [.integer(scheduled), .text(id), .text(day)])
        }
    }

    private func trafficAlert(id: String) throws -> TrafficAlertEvent? {
        try database.query("SELECT \(TrafficAlertRecord.columns) FROM traffic_alert_events WHERE id = ?",
                           [.text(id)], row: TrafficAlertRecord.read).first
    }
}
