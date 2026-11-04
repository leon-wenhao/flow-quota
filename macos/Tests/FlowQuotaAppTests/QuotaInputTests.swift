import Foundation
import Testing
@testable import FlowQuotaApp

@Test func localizedInputUsesExactSharedByteConversion() {
    let german = Locale(identifier: "de_DE")
    #expect(QuotaInput.bytes("1,25", unit: .gigabytes, locale: german) == 1_250_000_000)
    let locale = Locale(identifier: "en_US_POSIX")
    #expect(QuotaInput.bytes("9223372036854.775807", unit: .megabytes, locale: locale) == Int64.max)
    for input in ["", "0", "-1", "1e3", "0.0000001", "9223372036854.775808"] {
        #expect(QuotaInput.bytes(input, unit: .megabytes, locale: locale) == nil)
    }
}

@Test func unavailableUsageDoesNotBecomeZeroAndTotalsRejectOverflow() {
    #expect(UsageFormatter.bytes(nil) == "未知")
    #expect(UsageFormatter.bytes(-1) == "未知")
    #expect(UsageFormatter.bytes(0) != "未知")
    #expect(UsageFormatter.total([.max, 1]) == nil)
    #expect(UsageFormatter.total([10, -1]) == nil)
    #expect(UsageFormatter.total([1, 2]) == 3)
}
