import FlowQuotaCore
import Darwin
import Foundation
import FlowQuotaCore
import Testing
@testable import FlowQuotaPlatform

@Test func samplingClockAndDefaultParserUseContinuousMonotonicNanoseconds() throws {
    let before = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    let sample = SamplingClock.nowNanoseconds
    var parser = NettopParser()
    _ = try parser.append(Data(",bytes_in,bytes_out,\n".utf8))
    let after = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    let frames = try parser.append(Data(",bytes_in,bytes_out,\n".utf8))
    let first = try #require(frames.first)
    #expect(sample >= before && sample <= after)
    #expect(first.uptime >= before && first.uptime <= after)
}

@Test func counterRollbackReportsCanonicalSourcesIncludingSharedHelpers() throws {
    var accumulator = TrafficAccumulator()
    let app = AppIdentity(key: "app:/Example.app", name: "Example")
    let other = AppIdentity(key: "exec:/other", name: "Other")
    func counters(_ first: Int64, _ helper: Int64, _ healthy: Int64) -> [ResolvedProcessCounter] {
        [("first", app, first), ("helper", app, helper), ("other", other, healthy)].map {
            ResolvedProcessCounter(processKey: $0.0, identity: $0.1, uploadedBytes: 0, downloadedBytes: $0.2)
        }
    }
    _ = try accumulator.consume(counters(100, 100, 100), scope: "s", sequence: 1,
                                uptime: 1_000_000_000, countTraffic: true)
    let result = try accumulator.consume(counters(1, 110, 200), scope: "s", sequence: 2,
                                        uptime: 3_000_000_000, countTraffic: true)
    #expect(result.resetProcesses == 1)
    #expect(result.resetSourceKeys == [app.key])
    #expect(!result.rebaselined)
    #expect(result.increments.first { $0.identity.key == other.key }?.downloadedBytes == 100)
}
