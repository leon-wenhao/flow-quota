import Foundation
import Testing
@testable import FlowQuotaPlatform
import FlowQuotaCore

@Test func parserRequiresCompleteFramesAndHandlesFragmentedCSV() throws {
    var parser = NettopParser()
    #expect(try parser.append(Data(",bytes_in,bytes_out,\nName,with.dot.42,100,".utf8)).isEmpty)
    let frames = try parser.append(Data("200,\n,bytes_in,bytes_out,\n".utf8))
    #expect(frames.count == 1)
    #expect(frames.first?.counters == [ProcessCounter(pid: 42, uploadedBytes: 200, downloadedBytes: 100)])
    #expect(frames.first?.sequence == 1)
}

@Test func malformedNettopOutputFailsClosed() {
    for input in ["wrong-header\n", ",bytes_in,bytes_out,\na.1,-1,2,\n",
                  ",bytes_in,bytes_out,\na.1,1,2,\na.1,1,2,\n"] {
        var parser = NettopParser()
        #expect(throws: (any Error).self) { try parser.append(Data(input.utf8)) }
    }
}

private func counter(_ key: String, _ upload: Int64, _ download: Int64,
                     app: String = "app:/Example.app") -> ResolvedProcessCounter {
    ResolvedProcessCounter(processKey: key, identity: AppIdentity(key: app, name: "Example"),
                           uploadedBytes: upload, downloadedBytes: download)
}

@Test func countersOnlyAccumulateObservedContinuousIntervals() throws {
    var accumulator = TrafficAccumulator()
    let first = try accumulator.consume([counter("1:birth", 100, 200)], scope: "day:hotspot", sequence: 1,
                                       uptime: 1_000_000_000, countTraffic: true)
    #expect(first.rebaselined)
    #expect(first.increments.first?.uploadedBytes == 0)
    let next = try accumulator.consume([counter("1:birth", 120, 250), counter("2:birth", 99, 99)],
        scope: "day:hotspot", sequence: 2, uptime: 3_000_000_000, countTraffic: true)
    #expect(next.increments.first?.uploadedBytes == 20)
    #expect(next.increments.first?.downloadedBytes == 50)
    let reused = try accumulator.consume([counter("1:NEWbirth", 999, 999)], scope: "day:hotspot",
                                         sequence: 3, uptime: 5_000_000_000, countTraffic: true)
    #expect(reused.increments.first?.uploadedBytes == 0)
}

@Test func gapPathDayAndCounterResetNeverBackfill() throws {
    for kind in ["gap", "scope", "sleep", "reset", "ordinary"] {
        var accumulator = TrafficAccumulator()
        _ = try accumulator.consume([counter("1", 100, 100)], scope: "old", sequence: 1,
                                    uptime: 1_000_000_000, countTraffic: true)
        let result = try accumulator.consume([counter("1", kind == "reset" ? 1 : 500, 500)],
            scope: kind == "scope" ? "new" : "old", sequence: kind == "gap" ? 3 : 2,
            uptime: kind == "sleep" ? 20_000_000_000 : 3_000_000_000, countTraffic: kind != "ordinary")
        #expect(result.increments.first?.uploadedBytes == 0)
        #expect(result.increments.first?.downloadedBytes == 0)
    }
}

@Test func nestedApplicationHelpersGroupByOuterPath() {
    let app = ProcessIdentityResolver.identity(executable:
        URL(fileURLWithPath: "/Applications/Example.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"))
    #expect(app.key == "app:/Applications/Example.app")
    let tool = ProcessIdentityResolver.identity(executable: URL(fileURLWithPath: "/usr/bin/curl"))
    #expect(tool.key == "exec:/usr/bin/curl")
}

@Test func overflowDoesNotAdvanceBaseline() throws {
    var accumulator = TrafficAccumulator()
    _ = try accumulator.consume([counter("a", 0, 0), counter("b", 0, 0)], scope: "hotspot", sequence: 1,
                                uptime: 1_000_000_000, countTraffic: true)
    #expect(throws: (any Error).self) {
        try accumulator.consume([counter("a", .max, 0), counter("b", 1, 0)], scope: "hotspot", sequence: 2,
                                uptime: 3_000_000_000, countTraffic: true)
    }
    let retry = try accumulator.consume([counter("a", 2, 0)], scope: "hotspot", sequence: 2,
                                       uptime: 3_000_000_000, countTraffic: true)
    #expect(retry.increments.first?.uploadedBytes == 2)
}

@Test func processBornInsideObservedIntervalRetainsItsFirstBurst() throws {
    var accumulator = TrafficAccumulator()
    let start = Date(timeIntervalSince1970: 10_000)
    _ = try accumulator.consume([], scope: "hotspot", sequence: 1, uptime: 1_000_000_000,
                                countTraffic: true, capturedAt: start)
    let app = AppIdentity(key: "app", name: "App")
    let fresh = ResolvedProcessCounter(processKey: "fresh", identity: app, uploadedBytes: 500,
        downloadedBytes: 50_000, startedAt: start.addingTimeInterval(1))
    let old = ResolvedProcessCounter(processKey: "old", identity: app, uploadedBytes: 999_999,
        downloadedBytes: 999_999, startedAt: start.addingTimeInterval(-100))
    let result = try accumulator.consume([fresh, old], scope: "hotspot", sequence: 2,
        uptime: 3_000_000_000, countTraffic: true, capturedAt: start.addingTimeInterval(2))
    #expect(result.increments.first?.uploadedBytes == 500)
    #expect(result.increments.first?.downloadedBytes == 50_000)
    // Reappearing old processes must not receive the new-process exemption.
    _ = try accumulator.consume([], scope: "hotspot", sequence: 3, uptime: 5_000_000_000,
                                countTraffic: true, capturedAt: start.addingTimeInterval(4))
    let returnResult = try accumulator.consume([fresh], scope: "hotspot", sequence: 4,
        uptime: 7_000_000_000, countTraffic: true, capturedAt: start.addingTimeInterval(6))
    #expect(returnResult.increments.first?.uploadedBytes == 0)
}

@Test func minuteObservationKeysExcludeBaselinesGapsRollbacksAndUnknownProcessBirth() throws {
    var accumulator = TrafficAccumulator()
    let start = Date(timeIntervalSince1970: 10_000)
    let initial = try accumulator.consume([counter("a", 100, 200)], scope: "ordinary", sequence: 1,
        uptime: 1_000_000_000, countTraffic: true, capturedAt: start)
    #expect(initial.observedSourceKeys.isEmpty)
    let zero = try accumulator.consume([counter("a", 100, 200), counter("b", 1_000, 1_000, app: "unknown")],
        scope: "ordinary", sequence: 2, uptime: 3_000_000_000, countTraffic: true, capturedAt: start.addingTimeInterval(2))
    #expect(zero.observedSourceKeys == ["app:/Example.app"])
    let reset = try accumulator.consume([counter("a", 1, 200)], scope: "ordinary", sequence: 3,
        uptime: 5_000_000_000, countTraffic: true, capturedAt: start.addingTimeInterval(4))
    #expect(reset.observedSourceKeys.isEmpty)
    let gap = try accumulator.consume([counter("a", 999, 999)], scope: "ordinary", sequence: 4,
        uptime: 20_000_000_000, countTraffic: true, capturedAt: start.addingTimeInterval(19))
    #expect(gap.observedSourceKeys.isEmpty)
    let path = try accumulator.consume([counter("a", 1_000, 1_000)], scope: "metered", sequence: 5,
        uptime: 22_000_000_000, countTraffic: true, capturedAt: start.addingTimeInterval(21))
    #expect(path.observedSourceKeys.isEmpty)
    let fresh = ResolvedProcessCounter(processKey: "fresh", identity: AppIdentity(key: "fresh", name: "Fresh"),
        uploadedBytes: 7, downloadedBytes: 9, startedAt: start.addingTimeInterval(22))
    let birth = try accumulator.consume([fresh], scope: "metered", sequence: 6,
        uptime: 24_000_000_000, countTraffic: true, capturedAt: start.addingTimeInterval(23))
    #expect(birth.observedSourceKeys == ["fresh"])
    #expect(birth.increments.first?.uploadedBytes == 7)
}
