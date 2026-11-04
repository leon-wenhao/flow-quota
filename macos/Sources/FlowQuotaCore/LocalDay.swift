import Foundation

public enum QuotaIdentityError: Error, Equatable, Sendable {
    case invalidAppKey, invalidDay, invalidRuleVersion, unsupportedDate
}

/// Gregorian local date keys shared by the rules, ledger and persistence boundary.
public enum LocalDay {
    /// Recompute for every processing event, including wake, clock, time-zone and path changes.
    /// No cached midnight or fixed 86,400-second assumption; supports CE years 0001...9999.
    public static func key(for date: Date, in timeZone: TimeZone) throws -> String {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw QuotaIdentityError.unsupportedDate
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.era, .year, .month, .day], from: date)
        guard components.era == 1, let year = components.year, (1...9999).contains(year),
              let month = components.month, let day = components.day else {
            throw QuotaIdentityError.unsupportedDate
        }
        return "\(padded(year, width: 4))-\(padded(month, width: 2))-\(padded(day, width: 2))"
    }

    public static func isValidKey(_ key: String) -> Bool {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].utf8.count == 4,
              parts[1].utf8.count == 2, parts[2].utf8.count == 2,
              parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let year = Int(parts[0]), (1...9999).contains(year),
              let month = Int(parts[1]), (1...12).contains(month), let day = Int(parts[2]) else {
            return false
        }
        let leap = year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...lengths[month - 1]).contains(day)
    }

    private static func padded(_ value: Int, width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }
}

/// Stable app + local date + rule revision. A time-zone identifier is deliberately not a bucket:
/// changing zones without changing the local date must not grant a second daily allowance.
public struct QuotaIdentity: Codable, Hashable, Sendable {
    public let appKey: String
    public let day: String
    public let ruleVersion: Int64

    public init(appKey: String, day: String, ruleVersion: Int64) throws {
        guard AppKey.isCanonical(appKey) else {
            throw QuotaIdentityError.invalidAppKey
        }
        guard LocalDay.isValidKey(day) else { throw QuotaIdentityError.invalidDay }
        guard ruleVersion > 0 else { throw QuotaIdentityError.invalidRuleVersion }
        self.appKey = appKey
        self.day = day
        self.ruleVersion = ruleVersion
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(appKey: values.decode(String.self, forKey: .appKey),
                      day: values.decode(String.self, forKey: .day),
                      ruleVersion: values.decode(Int64.self, forKey: .ruleVersion))
    }
}
