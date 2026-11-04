import Foundation
import XCTest
@testable import FlowQuotaCore

final class LocalDayTests: XCTestCase {
    private func key(_ iso: String, _ zone: String) throws -> String {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: iso))
        return try LocalDay.key(for: date, in: XCTUnwrap(TimeZone(identifier: zone)))
    }

    func testLocalMidnightAndSleepAcrossMultipleDays() throws {
        XCTAssertEqual(try key("2026-11-03T15:59:59Z", "Asia/Shanghai"), "2026-11-03")
        XCTAssertEqual(try key("2026-11-03T16:00:00Z", "Asia/Shanghai"), "2026-11-04")
        // No midnight callback was delivered while asleep; first event derives the actual day.
        XCTAssertEqual(try key("2026-11-06T08:00:00Z", "Asia/Shanghai"), "2026-11-06")
    }

    func testExplicitTimezoneAndClockMoveRecomputeKeys() throws {
        XCTAssertEqual(try key("2026-11-04T00:30:00Z", "Asia/Shanghai"), "2026-11-04")
        XCTAssertEqual(try key("2026-11-04T00:30:00Z", "America/Los_Angeles"), "2026-11-03")
        XCTAssertEqual(try key("2026-11-03T00:30:00Z", "Asia/Shanghai"), "2026-11-03")
    }

    func testGregorianLeapYearAndDSTDays() throws {
        XCTAssertEqual(try key("2024-02-29T12:00:00Z", "UTC"), "2024-02-29")
        XCTAssertEqual(try key("2026-03-08T06:59:59Z", "America/New_York"), "2026-03-08")
        XCTAssertEqual(try key("2026-03-08T07:00:00Z", "America/New_York"), "2026-03-08")
        XCTAssertEqual(try key("2026-03-09T03:59:59Z", "America/New_York"), "2026-03-08")
        XCTAssertEqual(try key("2026-03-09T04:00:00Z", "America/New_York"), "2026-03-09")
        XCTAssertEqual(try key("2026-11-01T05:30:00Z", "America/New_York"), "2026-11-01")
        XCTAssertEqual(try key("2026-11-01T06:30:00Z", "America/New_York"), "2026-11-01")
    }

    func testDateAndIdentityValidationAndDecodedIdentity() throws {
        for day in ["2026-2-01", "2026-02-29", "1900-02-29", "0000-01-01", "2026-13-01", "2026-01-00"] {
            XCTAssertFalse(LocalDay.isValidKey(day), day)
        }
        XCTAssertTrue(LocalDay.isValidKey("2000-02-29"))
        XCTAssertThrowsError(try QuotaIdentity(appKey: " ", day: "2026-11-04", ruleVersion: 1))
        XCTAssertThrowsError(try QuotaIdentity(appKey: "a", day: "2026-11-04", ruleVersion: 0))
        XCTAssertThrowsError(try LocalDay.key(for: Date(timeIntervalSinceReferenceDate: .infinity),
                                             in: XCTUnwrap(TimeZone(secondsFromGMT: 0))))
        let identity = try QuotaIdentity(appKey: "signed.app", day: "2026-11-04", ruleVersion: 2)
        XCTAssertEqual(try JSONDecoder().decode(QuotaIdentity.self, from: JSONEncoder().encode(identity)), identity)
        let invalid = Data(#"{"appKey":"a","day":"2026-02-29","ruleVersion":1}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(QuotaIdentity.self, from: invalid))
    }
}
