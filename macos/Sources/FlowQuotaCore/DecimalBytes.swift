import Foundation

public enum DecimalByteUnit: String, Codable, Sendable {
    case MB, GB

    fileprivate var decimalPlaces: Int { self == .MB ? 6 : 9 }
}

public enum DecimalByteError: Error, Equatable, Sendable {
    case empty, invalidSyntax, fractionalByte, overflow
}

/// Parses locale-independent decimal MB/GB into nonnegative Int64 bytes, without floating point.
public enum DecimalBytes {
    /// Accepts surrounding whitespace, ASCII digits and one decimal point (digits on both sides).
    /// Rejects signs, exponents, separators, sub-byte precision and Int64 overflow. Zero is valid
    /// here; QuotaRule separately rejects zero limits. Trailing fractional zeroes are exact.
    public static func parse(_ text: String, unit: DecimalByteUnit) throws -> Int64 {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw DecimalByteError.empty }
        let parts = input.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ part in
            !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) }
        }) else { throw DecimalByteError.invalidSyntax }

        let fraction = parts.count == 2 ? Array(parts[1].utf8) : []
        let precision = unit.decimalPlaces
        guard fraction.dropFirst(precision).allSatisfy({ $0 == 48 }) else {
            throw DecimalByteError.fractionalByte
        }
        var result: Int64 = 0
        for digit in parts[0].utf8 { result = try append(digit - 48, to: result) }
        for index in 0..<precision {
            result = try append(index < fraction.count ? fraction[index] - 48 : 0, to: result)
        }
        return result
    }

    private static func append(_ digit: UInt8, to value: Int64) throws -> Int64 {
        let (scaled, multipliedOverflow) = value.multipliedReportingOverflow(by: 10)
        let (result, addedOverflow) = scaled.addingReportingOverflow(Int64(digit))
        guard !multipliedOverflow, !addedOverflow else { throw DecimalByteError.overflow }
        return result
    }
}
