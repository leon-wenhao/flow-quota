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
            let policy = try trafficAlertPolicy(category: event.category)
            guard TrafficAlertRecord.matchesPolicy(event, policy) else { return false }
            // Do not bound this query by the proposed occurrence/cooldown: an
            // occurrence behind the persisted maximum must suppress after restart.
            let latest = try database.query("""
                SELECT MAX(occurred_at_ms) FROM traffic_alert_events
                WHERE day = ? AND kind = ? AND source_key = ? AND policy_version = ? AND category = ?
                """, [.text(today), .text(event.kind.rawValue), .text(event.sourceKey), .integer(event.policyVersion), .text(event.category.rawValue)]) {
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
                INSERT INTO traffic_alert_events (\(TrafficAlertRecord.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, try TrafficAlertRecord.bindings(event))
            return true
        }
    }

    /// At most 256 most recent events; UUID descending makes timestamp ties stable.
    public func trafficAlertEvents(day: String, limit: Int = 256, offset: Int = 0, category: TrafficCategory = .metered) throws -> [TrafficAlertEvent] {
        try StoreDay.validate(day)
        guard (1...256).contains(limit), (0...256).contains(offset) else { throw TrafficAlertError.invalidEvent }
        return try database.query("""
            SELECT \(TrafficAlertRecord.columns) FROM traffic_alert_events
            WHERE day = ? AND category = ? ORDER BY occurred_at_ms DESC, id DESC LIMIT ? OFFSET ?
            """, [.text(day), .text(category.rawValue), .integer(Int64(limit)), .integer(Int64(offset))], row: TrafficAlertRecord.read)
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
            guard try TrafficAlertRecord.matchesPolicy(event, trafficAlertPolicy(category: event.category)) else { throw StoreError.staleTrafficAlertPolicy }
            if event.scheduledAt != nil { return }
            let scheduled = try TrafficAlertRecord.milliseconds(now)
            guard scheduled >= (try TrafficAlertRecord.milliseconds(event.occurredAt)) else { throw TrafficAlertError.invalidEvent }
            try database.execute("""
                UPDATE traffic_alert_events SET scheduled_at_ms = ? WHERE id = ? AND day = ? AND scheduled_at_ms IS NULL
                """, [.integer(scheduled), .text(id), .text(day)])
        }
    }

    public func trafficAlertDetails(id: String, day: String, category: TrafficCategory) throws -> TrafficAlertEvent {
        try StoreDay.validate(day)
        guard day == (try StoreDay.label(at: clock(), calendar: calendar)) else { throw StoreError.inactiveDay }
        guard let event = try trafficAlert(id: TrafficAlertRecord.identifier(id)),
              event.day == day, event.category == category else { throw StoreError.unknownTrafficAlert(id) }
        return event
    }

    /// One store-actor read freezes the latest committed daily attribution. It
    /// never converts attribution into interface usage or backfills older events.
    public func dailyAlertApplications(day: String, category: TrafficCategory, observedAt: Date) throws -> TrafficAlertApplications {
        guard try hasApplicationUsage(day: day, category: category) else {
            return .unavailable("预警触发时尚未观测到当天应用用量。")
        }
        let rows = try snapshot(day: day, category: category).filter { $0.usage.totalBytes > 0 }
            .sorted { $0.usage.totalBytes == $1.usage.totalBytes ? $0.id < $1.id : $0.usage.totalBytes > $1.usage.totalBytes }
        let applications = TrafficAlertApplications(items: rows.prefix(128).map {
            TrafficAlertApplication(identity: $0.identity, uploadedBytes: $0.usage.uploadedBytes,
                                    downloadedBytes: $0.usage.downloadedBytes)
        }, observedAt: observedAt, omittedCount: max(0, rows.count - 128))
        try applications.validate()
        return applications
    }

    private func trafficAlert(id: String) throws -> TrafficAlertEvent? {
        try database.query("SELECT \(TrafficAlertRecord.columns) FROM traffic_alert_events WHERE id = ?",
                           [.text(id)], row: TrafficAlertRecord.read).first
    }
}
