import Foundation
import FlowQuotaCore

extension QuotaStore {
    /// Atomically registers identities and adds up to 4096 observed deltas for a day.
    /// Keys must be NFC; names must be nonempty and NUL-free. Negative bytes and
    /// overflow (including outstanding budget liabilities) fail the entire sample.
    /// Zero deltas may register identities; duplicate keys add each delta in order.
    /// An optional independent interface delta commits in the same transaction;
    /// it must match the batch day. Nil leaves that meter unknown/unchanged.
    /// An empty app batch supports independent interface sampling cadence.
    /// interfaceObservedAt is ONLY supplied for a continuous measured delta; its
    /// minute summary commits with the total. Nil creates no time distribution.
    /// applicationObservedAt + observedApplicationKeys include measured app deltas only,
    /// including true zero; baseline-only sources must be omitted.
    /// Samples are additive, so callers must not retry an ambiguously committed sample.
    public func recordSample(day: String, increments: [UsageIncrement],
                             interfaceIncrement: InterfaceUsage? = nil, category: TrafficCategory = .metered,
                             applicationObservedAt: Date? = nil, observedApplicationKeys: Set<String> = [],
                             interfaceObservedAt: Date? = nil) throws {
        try StoreDay.validate(day)
        guard increments.count <= 4096 else {
            throw StoreError.configuration("A sample may contain at most 4096 increments")
        }
        guard interfaceObservedAt == nil || interfaceIncrement != nil else {
            throw StoreError.configuration("Minute observation requires an interface increment")
        }
        guard observedApplicationKeys.isSubset(of: Set(increments.map { $0.identity.key })),
              applicationObservedAt != nil || observedApplicationKeys.isEmpty else {
            throw StoreError.configuration("应用分钟观测身份必须属于同一采样批次")
        }
        let applicationMinute: Int64?
        if let applicationObservedAt {
            guard try StoreDay.label(at: applicationObservedAt, calendar: calendar) == day else {
                throw StoreError.configuration("应用分钟观测日期必须与批次一致")
            }
            applicationMinute = try StoreDay.milliseconds(applicationObservedAt) / 60_000 * 60_000
        } else { applicationMinute = nil }
        try database.transaction {
            for increment in increments {
                let delta = try validateDeltas(increment.uploadedBytes, increment.downloadedBytes)
                try registerApplication(increment.identity)
                let key = increment.identity.key
                if category == .metered {
                    _ = try checkedAdd(balance(appKey: key, day: day).chargedBytes, delta)
                }
                try addUsage(appKey: key, day: day, upload: increment.uploadedBytes,
                             download: increment.downloadedBytes, category: category)
                if let applicationMinute, observedApplicationKeys.contains(key) {
                    try addApplicationMinute(day: day, category: category, increment: increment, minute: applicationMinute)
                }
            }
            if let interfaceIncrement {
                try addInterfaceUsage(day: day, increment: interfaceIncrement, category: category)
                if let interfaceObservedAt {
                    try addInterfaceMinute(day: day, category: category, increment: interfaceIncrement, observedAt: interfaceObservedAt)
                }
            }
        }
    }

    public func hasApplicationUsage(day: String, category: TrafficCategory) throws -> Bool {
        try StoreDay.validate(day)
        return try database.scalar("SELECT EXISTS(SELECT 1 FROM daily_usage WHERE day = ? AND category = ?)",
            [.text(day), .text(category.rawValue)]) == 1
    }

    /// Durable OS scheduling acknowledgments for exactly the requested day, across
    /// rule versions. These receipts do not guarantee user-visible notification delivery.
    public func deliveredNotifications(day: String, category: TrafficCategory = .metered) throws -> Set<QuotaNotificationKey> {
        try StoreDay.validate(day)
        // Retention keeps this table small; a day scan needs no additional schema/index.
        let keys = try database.query("""
            SELECT app_key, kind, rule_version FROM notification_receipts WHERE day = ? AND category = ?
            """, [.text(day), .text(category.rawValue)]) { row in
                let key = row.text(0)
                try validateAppKey(key)
                let kind: QuotaNotificationKind
                switch row.text(1) {
                case "warning": kind = .warning
                case "exceeded": kind = .blocked
                default: throw StoreError.configuration("Unknown persisted notification kind")
                }
                return QuotaNotificationKey(
                    identity: try QuotaIdentity(appKey: key, day: day, ruleVersion: row.integer(2)),
                    kind: kind, category: category)
            }
        return Set(keys)
    }
}
