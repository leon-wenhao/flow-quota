import XCTest
@testable import FlowQuotaCore

final class DecimalBytesTests: XCTestCase {
    func testDecimalUnitsAreExact() throws {
        XCTAssertEqual(try DecimalBytes.parse("0.1", unit: .MB), 100_000)
        XCTAssertEqual(try DecimalBytes.parse("1.000001", unit: .MB), 1_000_001)
        XCTAssertEqual(try DecimalBytes.parse("0.000000001", unit: .GB), 1)
        XCTAssertEqual(try DecimalBytes.parse(" 001.2300000000\n", unit: .GB), 1_230_000_000)
        XCTAssertEqual(try DecimalBytes.parse("0", unit: .MB), 0)
        XCTAssertEqual(try DecimalBytes.parse("9223372036854.775807", unit: .MB), .max)
        XCTAssertEqual(try DecimalBytes.parse("9223372036.854775807", unit: .GB), .max)
    }

    func testInvalidGrammarAndSubByteValues() {
        for input in ["-1", "+1", ".5", "1.", "1,000", "1,5", "1e3", "NaN", "１２", "1 2", "1..2"] {
            XCTAssertThrowsError(try DecimalBytes.parse(input, unit: .MB)) {
                XCTAssertEqual($0 as? DecimalByteError, .invalidSyntax, input)
            }
        }
        XCTAssertThrowsError(try DecimalBytes.parse(" \n", unit: .GB)) {
            XCTAssertEqual($0 as? DecimalByteError, .empty)
        }
        XCTAssertThrowsError(try DecimalBytes.parse("0.0000001", unit: .MB)) {
            XCTAssertEqual($0 as? DecimalByteError, .fractionalByte)
        }
        XCTAssertThrowsError(try DecimalBytes.parse("1.0000000001", unit: .GB)) {
            XCTAssertEqual($0 as? DecimalByteError, .fractionalByte)
        }
    }

    func testOverflowNeverWrapsOrRounds() {
        for input in ["9223372036.854775808", "9223372037", String(repeating: "9", count: 100)] {
            XCTAssertThrowsError(try DecimalBytes.parse(input, unit: .GB)) {
                XCTAssertEqual($0 as? DecimalByteError, .overflow)
            }
        }
        XCTAssertThrowsError(try QuotaRule(limitBytes: DecimalBytes.parse("0", unit: .MB))) {
            XCTAssertEqual($0 as? RuleError, .invalidLimit)
        }
    }
}
