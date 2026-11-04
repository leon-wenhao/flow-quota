import Foundation
import FlowQuotaCore

/// Presentation only. All rule conversions stay in integer bytes, with decimal MB/GB.
enum UsageFormatter {
    static func bytes(_ value: Int64?) -> String {
        guard let value, value >= 0 else { return "未知" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB, .usePB, .useEB]
        formatter.includesActualByteCount = false
        formatter.zeroPadsFractionDigits = false
        return formatter.string(fromByteCount: value)
    }

    static func total(_ values: [Int64]) -> Int64? {
        var total: Int64 = 0
        for value in values {
            guard value >= 0 else { return nil }
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }
}

enum QuotaUnit: String, CaseIterable, Identifiable {
    case megabytes = "MB", gigabytes = "GB"
    var id: String { rawValue }
    var multiplier: Int64 { self == .megabytes ? 1_000_000 : 1_000_000_000 }
}

enum QuotaInput {
    /// Rejects exponents, grouping separators, fractional bytes and Int64 overflow.
    static func bytes(_ input: String, unit: QuotaUnit, locale: Locale = .current) -> Int64? {
        let separator = locale.decimalSeparator ?? "."
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: separator, with: ".")
        guard let bytes = try? DecimalBytes.parse(
            normalized, unit: unit == .megabytes ? .MB : .GB
        ), bytes > 0 else { return nil }
        return bytes
    }

    static func text(_ bytes: Int64, unit: QuotaUnit, locale: Locale = .current) -> String {
        let value = Decimal(bytes) / Decimal(unit.multiplier)
        return NSDecimalNumber(decimal: value).stringValue
            .replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
    }
}
