import Foundation
import FlowQuotaCore
import Testing
@testable import FlowQuotaApp

struct UsageTimelineDataTests {
    private let start = Date(timeIntervalSince1970: 1_793_750_400) // minute-aligned

    private func minute(_ offset: Int, upload: Int64 = 1, download: Int64 = 2,
                        samples: Int64 = 1) -> InterfaceUsageMinute {
        InterfaceUsageMinute(minuteStartMilliseconds: Int64(start.timeIntervalSince1970 * 1_000) + Int64(offset) * 60_000,
                             uploadedBytes: upload, downloadedBytes: download, sampleCount: samples)
    }

    @Test func fiveMinuteBucketsRespectHalfOpenRangeAndKeepUnknownDistinctFromZero() throws {
        let data = try #require(UsageTimelineData.make(minutes: [
            minute(-1, upload: 999), minute(0, upload: 10), minute(4, upload: 20),
            minute(10, upload: 0, download: 0), minute(60, upload: 999)
        ], start: start, end: start.addingTimeInterval(3_600)))
        #expect(data.slots.count == 12)
        #expect(data.bucketMinutes == 5)
        #expect(data.totalBytes == 34)
        #expect(data.slots[0].sampleCount == 2)
        #expect(data.slots[0].observedMinutes == 2)
        #expect(data.slots[1].sampleCount == 0) // unknown, never a measured zero
        #expect(data.slots[2].sampleCount == 1)
        #expect(data.slots[2].totalBytes == 0) // measured zero remains drawable
        #expect(data.slot(at: start.addingTimeInterval(300))?.id == data.slots[1].id)
        #expect(data.slot(at: data.interval.end) == nil)
    }

    @Test func todayAndCustomRangeAggregateWithoutSynthesizingObservation() throws {
        let data = try #require(UsageTimelineData.make(minutes: [minute(0), minute(29), minute(30)],
            start: start, end: start.addingTimeInterval(86_400)))
        #expect(data.bucketMinutes == 30)
        #expect(data.slots.count == 48)
        #expect(data.slots[0].sampleCount == 2)
        #expect(data.slots[1].sampleCount == 1)
        #expect(data.slots[2].sampleCount == 0)
        let empty = try #require(UsageTimelineData.make(minutes: [], start: start,
            end: start.addingTimeInterval(600)))
        #expect(empty.totalBytes == nil)
        #expect(empty.uploadedBytes == nil)
        #expect(empty.slots.allSatisfy { $0.sampleCount == 0 })
    }

    @Test func handlesPartialCurrentMinuteAndTwentyFiveHourDay() throws {
        let partial = try #require(UsageTimelineData.make(minutes: [minute(0, upload: 0, download: 0)],
            start: start.addingTimeInterval(5), end: start.addingTimeInterval(20)))
        #expect(partial.slots.count == 1)
        #expect(partial.totalBytes == 0)
        #expect(partial.interval.start == start)
        #expect(partial.interval.end == start.addingTimeInterval(60))
        let longDay = try #require(UsageTimelineData.make(minutes: [minute(1_499)],
            start: start, end: start.addingTimeInterval(90_000)))
        #expect(longDay.slots.count == 50)
        #expect(longDay.slots.last?.sampleCount == 1)
    }

    @Test func rejectsOverflowInvalidDuplicateRowsAndInvalidRanges() {
        for rows in [[minute(0, upload: -1)], [minute(0, samples: 0)], [minute(0), minute(0)],
                     [minute(0, upload: .max, download: 1)],
                     [minute(0, upload: .max, download: 0), minute(6)]] {
            #expect(UsageTimelineData.make(minutes: rows, start: start, end: start.addingTimeInterval(600)) == nil)
        }
        #expect(UsageTimelineData.make(minutes: [], start: start, end: start) == nil)
        #expect(UsageTimelineData.make(minutes: [], start: start, end: start.addingTimeInterval(-60)) == nil)
        #expect(UsageTimelineData.make(minutes: [], start: start, end: start.addingTimeInterval(200_000)) == nil)
    }
}
