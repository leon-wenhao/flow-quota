import Foundation
import FlowQuotaCore

extension QuotaStore {
    /// A consistent committed balance; includes expired/stale outstanding leases.
    public func budgetBalance(appKey: String, day: String) throws -> BudgetBalance {
        try validateAppKey(appKey)
        try StoreDay.validate(day)
        return try database.transaction {
            try requireApplication(appKey)
            return try balance(appKey: appKey, day: day)
        }
    }

    /// All-or-nothing durable grant in bytes. Use a globally unique ID and retry
    /// with identical arguments. No grant survives expiry, day or rule changes.
    /// Expiry must be future UTC time at/before the next local midnight.
    public func reserveBudget(id: String, appKey: String, day: String, bytes: Int64,
                              ruleVersion: Int64, expiresAt: Date) throws -> BudgetLease {
        try validateIdentifier(id)
        try validateAppKey(appKey)
        try StoreDay.validate(day)
        guard bytes > 0 else { throw StoreError.invalidBytes }
        let expiry = try StoreDay.milliseconds(expiresAt)
        return try database.transaction {
            let now = clock()
            let calendar = self.calendar
            guard day == (try StoreDay.label(at: now, calendar: calendar)) else { throw StoreError.inactiveDay }
            let nowMilliseconds = try StoreDay.milliseconds(now)
            guard let interval = calendar.dateInterval(of: .day, for: now),
                  expiry > nowMilliseconds,
                  expiry <= (try StoreDay.milliseconds(interval.end)) else { throw StoreError.invalidExpiry }
            let rule = try requireRule(appKey: appKey, version: ruleVersion)
            if let previous = try lease(id) {
                guard previous.value.appKey == appKey, previous.value.day == day,
                      previous.value.reservedBytes == bytes, previous.value.ruleVersion == ruleVersion,
                      previous.expiry == expiry else { throw StoreError.leaseConflict }
                guard !previous.value.isSettled else { throw StoreError.leaseInactive }
                return previous.value
            }
            let charged = try balance(appKey: appKey, day: day).chargedBytes
            let after = try checkedAdd(charged, bytes)
            if let limit = rule.limitBytes, after > limit { throw StoreError.quotaExceeded }
            try database.execute("""
                INSERT INTO budget_leases(lease_id, app_key, day, rule_version, reserved_bytes, expires_at_ms)
                VALUES (?, ?, ?, ?, ?, ?)
                """, [.text(id), .text(appKey), .text(day), .integer(ruleVersion), .integer(bytes), .integer(expiry)])
            return BudgetLease(id: id, appKey: appKey, day: day, ruleVersion: ruleVersion,
                               reservedBytes: bytes, expiresAt: Date(timeIntervalSince1970: Double(expiry) / 1_000),
                               uploadedBytes: nil, downloadedBytes: nil)
        }
    }

    /// FINAL cumulative lease counters, not deltas. Caller must have stopped the
    /// consumer and authenticated its final report before releasing unused budget.
    /// Unknown consumption after expiry stays conservatively charged until rollover.
    public func settleBudget(id: String, uploadedBytes: Int64,
                             downloadedBytes: Int64) throws -> BudgetLease {
        try validateIdentifier(id)
        let total = try validateDeltas(uploadedBytes, downloadedBytes)
        return try database.transaction {
            guard let persisted = try lease(id) else { throw StoreError.unknownLease(id) }
            let previous = persisted.value
            if previous.isSettled {
                guard previous.uploadedBytes == uploadedBytes, previous.downloadedBytes == downloadedBytes else {
                    throw StoreError.leaseConflict
                }
                return previous
            }
            let now = clock()
            guard previous.day == (try StoreDay.label(at: now, calendar: calendar)),
                  persisted.expiry > (try StoreDay.milliseconds(now)) else { throw StoreError.leaseInactive }
            guard total <= previous.reservedBytes else { throw StoreError.invalidBytes }
            // Read the entire liability before changing it; corrupt/overflowing
            // state must never be repaired by granting budget through a settlement.
            _ = try balance(appKey: previous.appKey, day: previous.day)
            try addUsage(appKey: previous.appKey, day: previous.day,
                         upload: uploadedBytes, download: downloadedBytes)
            try database.execute("UPDATE budget_leases SET uploaded_bytes = ?, downloaded_bytes = ? WHERE lease_id = ?",
                                 [.integer(uploadedBytes), .integer(downloadedBytes), .text(id)])
            return BudgetLease(id: previous.id, appKey: previous.appKey, day: previous.day,
                               ruleVersion: previous.ruleVersion, reservedBytes: previous.reservedBytes,
                               expiresAt: previous.expiresAt, uploadedBytes: uploadedBytes, downloadedBytes: downloadedBytes)
        }
    }

    func balance(appKey: String, day: String) throws -> BudgetBalance {
        let current = try usage(appKey: appKey, day: day)
        let actual = try checkedAdd(current.uploadedBytes, current.downloadedBytes)
        // SQLite's integer SUM reports overflow instead of promoting to REAL.
        let outstanding = try database.scalar("""
            SELECT COALESCE(SUM(reserved_bytes), 0) FROM budget_leases
            WHERE app_key = ? AND day = ? AND uploaded_bytes IS NULL
            """, [.text(appKey), .text(day)])
        return BudgetBalance(usedBytes: actual, outstandingBytes: outstanding,
                             chargedBytes: try checkedAdd(actual, outstanding))
    }

    private func lease(_ id: String) throws -> (value: BudgetLease, expiry: Int64)? {
        try database.query("""
            SELECT lease_id, app_key, day, rule_version, reserved_bytes, expires_at_ms,
                   uploaded_bytes, downloaded_bytes FROM budget_leases WHERE lease_id = ?
            """, [.text(id)]) { row in
                (BudgetLease(id: row.text(0), appKey: row.text(1), day: row.text(2),
                             ruleVersion: row.integer(3), reservedBytes: row.integer(4),
                             expiresAt: Date(timeIntervalSince1970: Double(row.integer(5)) / 1_000),
                             uploadedBytes: row.optionalInteger(6), downloadedBytes: row.optionalInteger(7)),
                 row.integer(5))
            }.first
    }
}
