import FlowQuotaCore

extension QuotaStore {
    /// Atomically registers identities and adds up to 4096 observed deltas for a day.
    /// Keys must be NFC; names must be nonempty and NUL-free. Negative bytes and
    /// overflow (including outstanding budget liabilities) fail the entire sample.
    /// Zero deltas may register identities; duplicate keys add each delta in order.
    /// An optional independent interface delta commits in the same transaction;
    /// it must match the batch day. Nil leaves that meter unknown/unchanged.
    /// An empty app batch supports independent interface sampling cadence.
    /// Samples are additive, so callers must not retry an ambiguously committed sample.
    public func recordSample(day: String, increments: [UsageIncrement],
                             interfaceIncrement: InterfaceUsage? = nil) throws {
        try StoreDay.validate(day)
        guard increments.count <= 4096 else {
            throw StoreError.configuration("A sample may contain at most 4096 increments")
        }
        try database.transaction {
            for increment in increments {
                let delta = try validateDeltas(increment.uploadedBytes, increment.downloadedBytes)
                try registerApplication(increment.identity)
                let key = increment.identity.key
                _ = try checkedAdd(balance(appKey: key, day: day).chargedBytes, delta)
                try addUsage(appKey: key, day: day, upload: increment.uploadedBytes,
                             download: increment.downloadedBytes)
            }
            if let interfaceIncrement {
                try addInterfaceUsage(day: day, increment: interfaceIncrement)
            }
        }
    }

    /// Durable OS scheduling acknowledgments for exactly the requested day, across
    /// rule versions. These receipts do not guarantee user-visible notification delivery.
    public func deliveredNotifications(day: String) throws -> Set<QuotaNotificationKey> {
        try StoreDay.validate(day)
        // Retention keeps this table small; a day scan needs no additional schema/index.
        let keys = try database.query("""
            SELECT app_key, kind, rule_version FROM notification_receipts WHERE day = ?
            """, [.text(day)]) { row in
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
                    kind: kind)
            }
        return Set(keys)
    }
}
