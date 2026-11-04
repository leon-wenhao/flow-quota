import Foundation
import FlowQuotaCore

/// Validation/admission failures are distinct from SQLite I/O/constraint failures.
public enum StoreError: Error, Equatable, Sendable {
    case sqlite(code: Int32, message: String)
    case rollbackFailed(original: String, rollback: String)
    case closed
    case unsupportedSchema(Int64)
    case invalidIdentifier
    case invalidDay(String)
    case invalidBytes
    case overflow
    case unknownApplication(String)
    case missingRule(String)
    case staleRuleVersion
    case quotaExceeded
    case invalidExpiry
    case inactiveDay
    case unknownLease(String)
    case leaseConflict
    case leaseInactive
    case configuration(String)
}

/// Shared domain vocabulary. The SQL spelling "exceeded" is retained for schema compatibility.
public typealias NotificationKind = QuotaNotificationKind

/// Committed grant. Only an unsettled, unexpired grant for the current rule/day
/// authorizes consumption; IPC callers must enforce those conditions continuously.
public struct BudgetLease: Equatable, Sendable {
    public let id: String
    public let appKey: String
    public let day: String
    public let ruleVersion: Int64
    public let reservedBytes: Int64
    public let expiresAt: Date
    public let uploadedBytes: Int64?
    public let downloadedBytes: Int64?
    public var isSettled: Bool { uploadedBytes != nil }
}

/// Actual counters and unknown outstanding consumption are deliberately separate.
public struct BudgetBalance: Equatable, Sendable {
    public let usedBytes: Int64
    public let outstandingBytes: Int64
    public let chargedBytes: Int64
}

func checkedAdd(_ left: Int64, _ right: Int64) throws -> Int64 {
    let (result, overflow) = left.addingReportingOverflow(right)
    guard !overflow else { throw StoreError.overflow }
    return result
}

func validateIdentifier(_ value: String) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !value.utf8.contains(0) else { throw StoreError.invalidIdentifier }
}

func validateDeltas(_ upload: Int64, _ download: Int64) throws -> Int64 {
    guard upload >= 0, download >= 0 else { throw StoreError.invalidBytes }
    return try checkedAdd(upload, download)
}

func validateAppKey(_ value: String) throws {
    try validateIdentifier(value)
    guard AppKey.isCanonical(value) else { throw StoreError.invalidIdentifier }
}
