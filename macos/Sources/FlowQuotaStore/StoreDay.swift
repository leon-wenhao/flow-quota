import Foundation
import FlowQuotaCore

/// Locale-independent Gregorian label. No permissive DateFormatter normalization.
enum StoreDay {
    static func validate(_ day: String) throws {
        guard LocalDay.isValidKey(day) else { throw StoreError.invalidDay(day) }
    }

    static func label(at date: Date, calendar: Calendar) throws -> String {
        try LocalDay.key(for: date, in: calendar.timeZone)
    }

    static func milliseconds(_ date: Date) throws -> Int64 {
        let value = (date.timeIntervalSince1970 * 1_000).rounded(.down)
        guard value.isFinite, value > 0, value < Double(Int64.max) else {
            throw StoreError.invalidExpiry
        }
        return Int64(value)
    }

    // Static identifiers only: reused in schema DDL, never supplied by a caller.
    static let sqlCheck = """
        typeof(day) = 'text' AND length(day) = 10
        AND day GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
        AND CAST(substr(day, 1, 4) AS INTEGER) BETWEEN 1 AND 9999
        AND CAST(substr(day, 6, 2) AS INTEGER) BETWEEN 1 AND 12
        AND CAST(substr(day, 9, 2) AS INTEGER) BETWEEN 1 AND
          CASE CAST(substr(day, 6, 2) AS INTEGER)
          WHEN 2 THEN 28 + (CAST(substr(day, 1, 4) AS INTEGER) % 4 = 0
            AND (CAST(substr(day, 1, 4) AS INTEGER) % 100 != 0
              OR CAST(substr(day, 1, 4) AS INTEGER) % 400 = 0))
          WHEN 4 THEN 30 WHEN 6 THEN 30 WHEN 9 THEN 30 WHEN 11 THEN 30 ELSE 31 END
        """
}
