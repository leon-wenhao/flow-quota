import Foundation
import Testing
import FlowQuotaCore
@testable import FlowQuotaPlatform

struct MihomoAttributionAccumulationTests {
    private static let origin = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_794_000_000))
        .addingTimeInterval(3_600)

    private static func connection(_ id: String = "a", upload: Int64, download: Int64? = nil,
                                   path: String = "/mihomo-regression/First", host: String = "youtube.com") -> [String: Any] {
        ["id": id, "upload": upload, "download": download ?? upload * 2,
         "metadata": ["processPath": path, "host": host], "chains": []]
    }

    private struct Harness {
        var accumulator = MihomoProxyAccumulator()
        var day: String { get throws { try LocalDay.key(for: origin, in: .current) } }

        @discardableResult
        mutating func sample(_ total: Int64, at seconds: TimeInterval,
                             category: TrafficCategory? = .metered, scope: String = "path",
                             uptime: UInt64? = nil, connections: [[String: Any]]? = nil,
                             download: Int64? = nil) throws -> MihomoProxySnapshot {
            let json: [String: Any] = ["uploadTotal": total, "downloadTotal": download ?? total * 2,
                                      "connections": connections ?? [connection(upload: total)]]
            let response = try MihomoAPIResponse.decode(JSONSerialization.data(withJSONObject: json))
            return try accumulator.consume(response, scope: scope, capturedAt: origin.addingTimeInterval(seconds),
                category: category, uptime: uptime ?? UInt64(seconds * 1_000_000_000) + 1)
        }

        func snapshot(_ category: TrafficCategory? = .metered) throws -> MihomoProxySnapshot {
            accumulator.snapshot(category: category, day: try day, status: .observing)
        }
    }

    @Test func closedAndReopenedConnectionsRetainCumulativeSourceIncrements() throws {
        var harness = Harness()
        let first = try harness.sample(100, at: 0)
        #expect(first.totalBytes == 0)
        #expect(first.sources.first?.totalBytes == 0)
        let earned = try harness.sample(110, at: 2)
        #expect(earned.uploadedBytes == 10)
        #expect(earned.downloadedBytes == 20)
        #expect(earned.sources.first?.totalBytes == 30)
        let closed = try harness.sample(150, at: 4, connections: [])
        #expect(closed.uploadedBytes == 50)
        #expect(closed.downloadedBytes == 100)
        #expect(closed.sources == earned.sources.map {
            MihomoProxySource(id: $0.id, displayName: $0.displayName, connectionCount: 0,
                uploadedBytes: $0.uploadedBytes, downloadedBytes: $0.downloadedBytes,
                appIdentity: $0.appIdentity, siteName: $0.siteName, viaClash: $0.viaClash)
        })
        #expect(closed.activeConnectionCount == 0)
        let reopened = try harness.sample(200, at: 6, connections: [Self.connection("new", upload: 9_000)])
        #expect(reopened.sources.first?.totalBytes == 30)
        let increment = try harness.sample(210, at: 8, connections: [Self.connection("new", upload: 9_005)])
        #expect(increment.sources.count == 1)
        #expect(increment.sources.first?.uploadedBytes == 15)
        #expect(increment.sources.first?.downloadedBytes == 30)
        #expect(increment.activeConnectionCount == 1)
    }

    @Test func simultaneousConnectionsAggregateByStableSourceRatherThanConnectionID() throws {
        var harness = Harness()
        _ = try harness.sample(1_000, at: 0, connections: [
            Self.connection("a", upload: 100), Self.connection("b", upload: 200)])
        let next = try harness.sample(1_100, at: 2, connections: [
            Self.connection("a", upload: 110), Self.connection("b", upload: 230)])
        #expect(next.sources.count == 1)
        #expect(next.sources.first?.uploadedBytes == 40)
        #expect(next.sources.first?.downloadedBytes == 80)
        #expect(next.sources.first?.connectionCount == 2)
        #expect(next.uploadedBytes == 100) // API totals need not equal attributable connections.
    }

    @Test func categoriesKeepSeparateSubtotalsAndUnknownNeverAllocatesOrBridges() throws {
        var harness = Harness()
        _ = try harness.sample(100, at: 0)
        _ = try harness.sample(120, at: 2)
        _ = try harness.sample(1_000, at: 4, category: .ordinary)
        _ = try harness.sample(1_030, at: 6, category: .ordinary)
        for (seconds, bytes) in [(8.0, Int64(5_000)), (10.0, Int64(7_000))] {
            let unknown = try harness.sample(bytes, at: seconds, category: nil)
            #expect(unknown.category == nil)
            #expect(unknown.totalBytes == 0)
            #expect(unknown.sources.isEmpty)
            #expect(unknown.sampledAt == nil)
        }
        let restored = try harness.sample(8_000, at: 12)
        #expect(restored.totalBytes == 60)
        let next = try harness.sample(8_005, at: 14)
        #expect(next.uploadedBytes == 25)
        #expect(next.sources.first?.downloadedBytes == 50)
        let ordinary = try harness.snapshot(.ordinary)
        #expect(ordinary.uploadedBytes == 30)
        #expect(ordinary.sources.first?.downloadedBytes == 60)
        #expect(ordinary.sampledAt == Self.origin.addingTimeInterval(6))
    }

    @Test func localDayChangeClearsBothCategoriesAndDoesNotFillTheMidnightGap() throws {
        var harness = Harness()
        _ = try harness.sample(100, at: 0)
        _ = try harness.sample(110, at: 2)
        _ = try harness.sample(200, at: 4, category: .ordinary)
        _ = try harness.sample(220, at: 6, category: .ordinary)
        let tomorrow = try #require(Calendar.current.date(byAdding: .day, value: 1, to: Self.origin))
        let offset = tomorrow.timeIntervalSince(Self.origin)
        let baseline = try harness.sample(10_000, at: offset, uptime: 8_000_000_001)
        #expect(baseline.day == (try LocalDay.key(for: tomorrow, in: .current)))
        #expect(baseline.totalBytes == 0)
        #expect(baseline.sources.first?.totalBytes == 0)
        for category in TrafficCategory.allCases {
            #expect(try harness.snapshot(category).sources.isEmpty)
            let current = harness.accumulator.snapshot(category: category, day: try #require(baseline.day), status: .observing)
            if category == .ordinary { #expect(current.sampledAt == nil) }
            #expect(current.totalBytes == 0)
        }
        let next = try harness.sample(10_005, at: offset + 2, uptime: 10_000_000_001)
        #expect(next.totalBytes == 15)
        #expect(next.sources.first?.totalBytes == 15)
    }

    @Test(arguments: ["uptimeGap", "uptimeRollback", "uptimeEqual", "wallGap", "wallRollback"])
    func discontinuitiesDiscardUnknownIntervalsButKeepEarnedBytes(reason: String) throws {
        var harness = Harness()
        _ = try harness.sample(100, at: 0)
        _ = try harness.sample(110, at: 2)
        let seconds: Double = reason == "wallGap" ? 11 : reason == "wallRollback" ? 1 : 4
        let uptime: UInt64 = reason == "uptimeGap" ? 11_000_000_001
            : reason == "uptimeRollback" ? 1 : reason == "uptimeEqual" ? 2_000_000_001 : 4_000_000_001
        let baseline = try harness.sample(1_000, at: seconds, uptime: uptime)
        #expect(baseline.totalBytes == 30)
        #expect(baseline.sources.first?.totalBytes == 30)
        let next = try harness.sample(1_005, at: seconds + 2, uptime: uptime + 2_000_000_000)
        #expect(next.totalBytes == 45)
        #expect(next.sources.first?.totalBytes == 45)
    }

    @Test func eightSecondContinuityBoundaryStillCounts() throws {
        var harness = Harness()
        _ = try harness.sample(100, at: 0)
        let next = try harness.sample(110, at: 8)
        #expect(next.totalBytes == 30)
        #expect(next.sources.first?.totalBytes == 30)
    }

    @Test func changedScopeAndExplicitBaselineResetPreserveSubtotals() throws {
        var harness = Harness()
        _ = try harness.sample(100, at: 0)
        _ = try harness.sample(110, at: 2)
        let switched = try harness.sample(1_000, at: 4, scope: "another-path")
        #expect(switched.totalBytes == 30)
        #expect(switched.sources.first?.totalBytes == 30)
        _ = try harness.sample(1_005, at: 6, scope: "another-path")
        harness.accumulator.resetBaseline()
        let resumed = try harness.sample(9_000, at: 8, scope: "another-path")
        #expect(resumed.totalBytes == 45)
        #expect(resumed.sources.first?.totalBytes == 45)
        #expect(try harness.sample(9_002, at: 10, scope: "another-path").totalBytes == 51)
    }

    @Test(arguments: [true, false], [true, false])
    func rollbackOfEitherDirectionRebaselinesTheCorrectCounterPair(global: Bool, upload: Bool) throws {
        var harness = Harness()
        _ = try harness.sample(1_000, at: 0, connections: [Self.connection(upload: 100)])
        _ = try harness.sample(1_100, at: 2, connections: [Self.connection(upload: 110)])
        let totalUp: Int64 = global && upload ? 50 : 1_200
        let totalDown: Int64 = global && !upload ? 50 : 2_400
        let sourceUp: Int64 = !global && upload ? 5 : 120
        let sourceDown: Int64 = !global && !upload ? 5 : 240
        let reset = try harness.sample(totalUp, at: 4,
            connections: [Self.connection(upload: sourceUp, download: sourceDown)], download: totalDown)
        #expect(reset.uploadedBytes == (global ? 100 : 200))
        #expect(reset.downloadedBytes == (global ? 200 : 400))
        #expect(reset.sources.first?.uploadedBytes == 10)
        #expect(reset.sources.first?.downloadedBytes == 20)
        let next = try harness.sample(totalUp + 10, at: 6,
            connections: [Self.connection(upload: sourceUp + 2, download: sourceDown + 3)], download: totalDown + 20)
        #expect(next.uploadedBytes == (global ? 110 : 210))
        #expect(next.downloadedBytes == (global ? 220 : 420))
        #expect(next.sources.first?.uploadedBytes == 12)
        #expect(next.sources.first?.downloadedBytes == 23)
    }

    @Test(arguments: [true, false])
    func metadataIdentityChangesNeverAssignAnIntervalToItsNewOwner(changeProcess: Bool) throws {
        var harness = Harness()
        _ = try harness.sample(100, at: 0)
        let earned = try harness.sample(110, at: 2)
        let oldID = try #require(earned.sources.first?.id)
        let path = changeProcess ? "/mihomo-regression/Second" : "/mihomo-regression/First"
        let host = changeProcess ? "youtube.com" : "huya.com"
        let changed = try harness.sample(200, at: 4, connections: [Self.connection(upload: 200, path: path, host: host)])
        #expect(changed.totalBytes == 300)
        #expect(changed.sources.count == 2)
        #expect(changed.sources.first { $0.id == oldID }?.totalBytes == 30)
        #expect(changed.sources.first { $0.id == oldID }?.connectionCount == 0)
        #expect(changed.sources.first { $0.id != oldID }?.totalBytes == 0)
        let next = try harness.sample(205, at: 6, connections: [Self.connection(upload: 205, path: path, host: host)])
        #expect(next.sources.first { $0.id != oldID }?.totalBytes == 15)
        #expect(next.sources.first { $0.id == oldID }?.totalBytes == 30)
    }

    @Test func sourceCapacityIsVisibleBoundedAndIndependentForEachCategory() throws {
        var harness = Harness()
        func connections(_ count: Int, bytes: Int64) -> [[String: Any]] {
            (0..<count).map { Self.connection("id-\($0)", upload: bytes, path: "/mihomo-regression/source-\($0)") }
        }
        let full = try harness.sample(1_000, at: 0, connections: connections(128, bytes: 100))
        #expect(full.sources.count == 128)
        #expect(!full.message.contains("128"))
        let limited = try harness.sample(2_000, at: 2, connections: connections(129, bytes: 101))
        #expect(limited.sources.count == 128)
        #expect(limited.activeConnectionCount == 128)
        #expect(limited.sources.allSatisfy { $0.uploadedBytes == 1 && $0.downloadedBytes == 2 })
        #expect(limited.totalBytes == 3_000)
        #expect(limited.message.contains("128"))
        let closed = try harness.sample(3_000, at: 4, connections: [])
        #expect(closed.sources.count == 128)
        #expect(closed.activeConnectionCount == 0)
        #expect(closed.message.contains("128"))
        let ordinary = try harness.sample(4_000, at: 6, category: .ordinary, connections: connections(128, bytes: 500))
        #expect(ordinary.sources.count == 128)
        #expect(!ordinary.message.contains("128"))
        #expect(ordinary.totalBytes == 0)
        #expect(try harness.snapshot().totalBytes == 6_000)
    }
}
