import Foundation
import Testing
@testable import FlowQuotaCore

struct ClashUsageBreakdownTests {
    let kernel = AppIdentity(key: "exec:/Library/Application Support/clash-verge-service/cores/verge-mihomo", name: "Mihomo")
    func source(_ id: String, _ up: Int64, _ down: Int64, identified: Bool = true) -> ClashUsageSource {
        ClashUsageSource(id: id, name: id + "（Clash）", uploadedBytes: up, downloadedBytes: down, identified: identified)
    }

    func source(_ id: String, _ down: Int64, identified: Bool = true) -> ClashUsageSource {
        source(id, 0, down, identified: identified)
    }

    @Test func eightHundredMegabytesAlwaysRemainAndParentIsNotAddedAgain() throws {
        let result = try ClashUsageBreakdown.split(upload: 0, download: 800_000_000,
            sources: [source("虎牙", 300_000_000), source("YouTube", 300_000_000), source("unknown", 90_000_000, identified: false)])
        #expect(result.sources.count == 3)
        #expect(result.sources.first { !$0.identified }?.downloadedBytes == 200_000_000)
        #expect(result.sources.reduce(0) { $0 + $1.downloadedBytes } == 800_000_000)
        #expect(result.notice == nil)
    }

    @Test func missingOverBudgetDirectionAndOverflowNeverShrinkParent() throws {
        for sources in [[], [source("YouTube", 1, 100)], [source("YouTube", 0, 801)],
                        [source("A", Int64.max, 1)], [source("A", Int64.max, 0), source("B", 1, 0)]] {
            let result = try ClashUsageBreakdown.split(upload: 0, download: 800, sources: sources)
            #expect(result.sources == [ClashUsageBreakdown.unknown(upload: 0, download: 800)])
        }
        #expect(throws: ClashBreakdownError.self) { try ClashUsageBreakdown.split(upload: .max, download: 1, sources: []) }
    }

    @Test func conflictingMinuteCannotBorrowAnotherMinutesUnusedParent() throws {
        let parents = [0, 60_000].map { minute in
            ApplicationUsageBucket(appKey: kernel.key, name: kernel.name, startMilliseconds: Int64(minute),
                uploadedBytes: 0, downloadedBytes: 400, sampleCount: 1)
        }
        let result = try ClashMinuteBreakdown.resolve(processes: parents,
            sources: [ClashMinuteUsage(minute: 0, source: source("YouTube", 500)),
                      ClashMinuteUsage(minute: 60_000, source: source("YouTube", 100))])
        let grouped = try ClashMinuteBreakdown.group(result.rows, start: 0, step: 300_000)
        #expect(grouped.first { $0.clashSourceID == ClashUsageBreakdown.unknownID }?.downloadedBytes == 700)
        #expect(grouped.first { $0.clashSourceID == "YouTube" }?.downloadedBytes == 100)
        #expect(result.notice != nil)
        let noParent = try ClashMinuteBreakdown.resolve(processes: [], sources: [ClashMinuteUsage(minute: 0, source: source("YouTube", 900))])
        #expect(noParent.rows.isEmpty)
    }

    @Test func alertPreservesTriggerIdentityAndRoundTripsChildren() throws {
        let evidence = TrafficAlertApplications(items: [TrafficAlertApplication(identity: kernel, uploadedBytes: 0,
            downloadedBytes: 800)], observedAt: Date()).resolvingClash([source("YouTube", 300), source("虎牙", 300)])
        try evidence.validate()
        #expect(evidence.items.count == 1)
        #expect(evidence.items[0].identity == kernel)
        #expect(evidence.displaySources.count == 3)
        #expect(evidence.displaySources.reduce(0) { $0 + $1.downloadedBytes } == 800)
        let decoded = try JSONDecoder().decode(TrafficAlertApplications.self, from: JSONEncoder().encode(evidence))
        #expect(decoded == evidence)
        #expect(decoded.summary.contains("其他未识别"))
    }

    @Test func invalidAlertChildrenFailValidationWithoutCrashingTheSummary() throws {
        let bad = TrafficAlertApplications(items: [TrafficAlertApplication(identity: kernel, uploadedBytes: 0,
            downloadedBytes: 800, clashSources: [source("overflow", Int64.max, 1), source("other", 1)])], observedAt: Date())
        #expect(!bad.summary.isEmpty)
        #expect(throws: (any Error).self) { try bad.validate() }
        var window = ClashAlertSourceWindow()
        #expect(throws: TrafficAlertError.self) {
            try window.consume([], start: 1, end: 2, scope: "test", windowSeconds: -1)
        }
    }

    @Test func alertWindowRejectsCrossingFutureWrongCategoryAndDiscontinuousEvidence() throws {
        var window = ClashAlertSourceWindow()
        let billion: UInt64 = 1_000_000_000
        for index in 1...3 {
            try window.consume([source("YouTube", 100)], start: UInt64(index) * billion,
                end: UInt64(index + 1) * billion, scope: "ordinary:day:path:policy", windowSeconds: 180)
        }
        let sources = window.sources(since: 2 * billion, through: 3 * billion, scope: "ordinary:day:path:policy")
        #expect(sources.first?.downloadedBytes == 100)
        #expect(window.sources(since: billion, through: 4 * billion, scope: "metered:day:path:policy").isEmpty)
        try window.consume([], start: nil, end: 5 * billion, scope: "ordinary:day:path:policy", windowSeconds: 180)
        #expect(window.sources(since: billion, through: 5 * billion, scope: "ordinary:day:path:policy").isEmpty)
    }
}
