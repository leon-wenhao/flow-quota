import FlowQuotaCore

extension QuotaStore {
    public func trafficAlertPolicy(category: TrafficCategory = .metered) throws -> TrafficAlertPolicy {
        guard let policy = try database.query("""
            SELECT daily_interface_bytes, interface_burst_bytes, application_burst_bytes,
                   window_seconds, cooldown_seconds, version FROM traffic_alert_settings WHERE category = ?
            """, [.text(category.rawValue)], row: { row in
                try TrafficAlertPolicy(dailyInterfaceBytes: row.optionalInteger(0),
                    interfaceBurstBytes: row.optionalInteger(1), applicationBurstBytes: row.optionalInteger(2),
                    windowSeconds: Int(row.integer(3)), cooldownSeconds: Int(row.integer(4)), version: row.integer(5))
            }).first else {
            throw StoreError.configuration("Missing traffic alert settings category")
        }
        return policy
    }

    /// Revalidate decoded input. Exact retries succeed; changed content needs a
    /// strictly larger version, including when all thresholds are disabled.
    public func saveTrafficAlertPolicy(_ policy: TrafficAlertPolicy, category: TrafficCategory = .metered) throws {
        try policy.validate()
        try database.transaction {
            let previous = try trafficAlertPolicy(category: category)
            if policy == previous { return }
            guard policy.version > previous.version else { throw StoreError.staleTrafficAlertPolicy }
            try database.execute("""
                UPDATE traffic_alert_settings SET daily_interface_bytes = ?, interface_burst_bytes = ?,
                  application_burst_bytes = ?, window_seconds = ?, cooldown_seconds = ?, version = ? WHERE category = ?
                """, [.optional(policy.dailyInterfaceBytes), .optional(policy.interfaceBurstBytes),
                      .optional(policy.applicationBurstBytes), .integer(Int64(policy.windowSeconds)),
                      .integer(Int64(policy.cooldownSeconds)), .integer(policy.version), .text(category.rawValue)])
        }
    }
}
