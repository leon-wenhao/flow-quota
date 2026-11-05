import Darwin
import Foundation
import Testing
@testable import FlowQuotaPlatform

private let proxyPath = "/Library/Application Support/clash-verge-service/cores/verge-mihomo"
private let sampleDate = Date(timeIntervalSince1970: 200)
private let sampleCounter = ProcessCounter(pid: 42, uploadedBytes: 100, downloadedBytes: 200)

private func resolver(birth: Int64 = 100, path: String? = proxyPath) -> ProcessIdentityResolver {
    ProcessIdentityResolver(readBirth: { _ in ProcessBirthStamp(seconds: birth, microseconds: 123_456) },
                            readPath: { _ in path })
}

@Test func proxyCoreKeepsAnIndependentExecutableIdentity() throws {
    let result = try #require(resolver().resolve(sampleCounter, capturedAt: sampleDate))
    #expect(result.identity.key == "exec:" + proxyPath)
    #expect(result.processKey == "42:100.123456:" + proxyPath)
    #expect(result.uploadedBytes == 100)
    #expect(result.downloadedBytes == 200)
    #expect(result.startedAt == Date(timeIntervalSince1970: 100.123456))
}

@Test func missingBirthPathOrFutureBirthRejectsAttribution() {
    let noBirth = ProcessIdentityResolver(readBirth: { _ in nil }, readPath: { _ in proxyPath })
    #expect(noBirth.resolve(sampleCounter, capturedAt: sampleDate) == nil)
    #expect(resolver(birth: 201).resolve(sampleCounter, capturedAt: sampleDate) == nil)
    for path in [nil, "", "relative/mihomo", "/tmp/mi\0homo"] as [String?] {
        #expect(resolver(path: path).resolve(sampleCounter, capturedAt: sampleDate) == nil)
    }
    for counter in [ProcessCounter(pid: 0, uploadedBytes: 0, downloadedBytes: 0),
                    ProcessCounter(pid: 42, uploadedBytes: -1, downloadedBytes: 0)] {
        #expect(resolver().resolve(counter, capturedAt: sampleDate) == nil)
    }
}

/// Thread-safe scripted metadata models exit/PID reuse between the two reads.
private final class BirthSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ProcessBirthStamp?]
    init(_ seconds: [Int64?]) {
        values = seconds.map { $0.flatMap { ProcessBirthStamp(seconds: $0, microseconds: 0) } }
    }
    func next(_ pid: Int32) -> ProcessBirthStamp? {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty ? nil : values.removeFirst()
    }
}

@Test func processExitingOrReusingPIDWhileReadingPathIsRejected() {
    for seconds: [Int64?] in [[100, 101], [100, nil]] {
        let births = BirthSequence(seconds)
        let reader = ProcessIdentityResolver(readBirth: births.next, readPath: { _ in proxyPath })
        #expect(reader.resolve(sampleCounter, capturedAt: sampleDate) == nil)
    }
}

@Test func switchingMetadataAPIKeepsProxyDeltaAndPIDReuseRebaselines() throws {
    let bsdReader = ProcessBirthReader(bsdQuery: { pid, info in
        info.pbi_pid = UInt32(pid)
        info.pbi_start_tvsec = 100
        info.pbi_start_tvusec = 123_456
        return (Int32(MemoryLayout<proc_bsdinfo>.size), 0)
    })
    let kernelReader = ProcessBirthReader(bsdQuery: { _, _ in (0, EPERM) }, kernelQuery: { pid, info in
        info.kp_proc.p_pid = pid
        info.kp_proc.p_un.__p_starttime = timeval(tv_sec: 100, tv_usec: 123_456)
        return (0, MemoryLayout<kinfo_proc>.size)
    })
    let before = ProcessIdentityResolver(readBirth: bsdReader.read, readPath: { _ in proxyPath })
    let after = ProcessIdentityResolver(readBirth: kernelReader.read, readPath: { _ in proxyPath })
    var accumulator = TrafficAccumulator()
    let first = try #require(before.resolve(sampleCounter, capturedAt: sampleDate))
    let baseline = try accumulator.consume([first], scope: "day:metered", sequence: 1,
        uptime: 1_000_000_000, countTraffic: true, capturedAt: sampleDate)
    #expect(baseline.increments.first?.uploadedBytes == 0)
    #expect(baseline.increments.first?.downloadedBytes == 0)
    let nextCounter = ProcessCounter(pid: 42, uploadedBytes: 140, downloadedBytes: 260)
    let next = try #require(after.resolve(nextCounter, capturedAt: sampleDate.addingTimeInterval(2)))
    #expect(first.processKey == next.processKey)
    let delta = try accumulator.consume([next], scope: "day:metered", sequence: 2,
        uptime: 3_000_000_000, countTraffic: true, capturedAt: sampleDate.addingTimeInterval(2))
    #expect(delta.increments.first?.uploadedBytes == 40)
    #expect(delta.increments.first?.downloadedBytes == 60)
    #expect(delta.increments.first?.identity.key == "exec:" + proxyPath)
    // Reused PID born before this observed interval must never backfill old bytes.
    let reused = try #require(resolver(birth: 150).resolve(nextCounter, capturedAt: sampleDate.addingTimeInterval(4)))
    #expect(reused.processKey != next.processKey)
    let reset = try accumulator.consume([reused], scope: "day:metered", sequence: 3,
        uptime: 5_000_000_000, countTraffic: true, capturedAt: sampleDate.addingTimeInterval(4))
    #expect(reset.increments.first?.uploadedBytes == 0)
    #expect(reset.increments.first?.downloadedBytes == 0)
}
