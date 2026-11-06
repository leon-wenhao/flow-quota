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

    /// Compact decimal units for the menu bar only; full units remain in the
    /// tooltip/panel. Integer rounding keeps output at most four ASCII characters.
    static func compactBytes(_ value: Int64?) -> String {
        guard let value, value >= 0 else { return "—" }
        let units: [(bytes: Int64, suffix: String)] = [
            (1, "B"), (1_000, "K"), (1_000_000, "M"), (1_000_000_000, "G"),
            (1_000_000_000_000, "T"), (1_000_000_000_000_000, "P"), (1_000_000_000_000_000_000, "E")
        ]
        let index = units.lastIndex { value >= $0.bytes } ?? 0
        let unit = units[index]
        guard index > 0 else { return "\(value)B" }
        let whole = value / unit.bytes
        if whole >= 10 {
            let rounded = whole + (value % unit.bytes >= unit.bytes / 2 ? 1 : 0)
            if rounded == 1_000, index + 1 < units.count { return "1" + units[index + 1].suffix }
            return "\(rounded)\(unit.suffix)"
        }
        let tenth = unit.bytes / 10
        let rounded = value / tenth + (value % tenth >= tenth / 2 ? 1 : 0)
        let number = rounded % 10 == 0 ? "\(rounded / 10)" : "\(rounded / 10).\(rounded % 10)"
        return number + unit.suffix
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
