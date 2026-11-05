import Darwin
import Foundation
import FlowQuotaCore
import FlowQuotaStore
import Testing
@testable import FlowQuotaPlatform
@testable import FlowQuotaAgent

@Test func deniedRootProxyIdentityFlowsIntoItsOwnLedgerAndAlert() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try QuotaStore(path: folder.appendingPathComponent("quota.sqlite").path)
    let path = NetworkObservation(state: .expensive, message: "simulated", generation: 7, interfaceIndexes: [4])
    let runtime = AgentRuntime(store: store, networkObservation: { path })
    let birth = ProcessBirthReader(bsdQuery: { _, _ in (0, EPERM) }, kernelQuery: { pid, info in
        info.kp_proc.p_pid = pid
        info.kp_proc.p_un.__p_starttime = timeval(tv_sec: 100, tv_usec: 1)
        return (0, MemoryLayout<kinfo_proc>.size)
    })
    let resolver = ProcessIdentityResolver(readBirth: birth.read, readPath: { _ in
        "/Library/Application Support/clash-verge-service/cores/verge-mihomo"
    })
    let now = Date()
    let day = try LocalDay.key(for: now, in: .current)
    var accumulator = TrafficAccumulator()
    // Synthetic counters only: no nettop, interface reads, or live network traffic.
    for sequence: UInt64 in 1...2 {
        let row = try #require(resolver.resolve(ProcessCounter(pid: 42,
            uploadedBytes: sequence == 1 ? 100 : 10_000_100,
            downloadedBytes: sequence == 1 ? 200 : 240_000_200), capturedAt: now))
        let uptime = sequence * 2_000_000_000
        let result = try accumulator.consume([row], scope: "simulated", sequence: sequence,
            uptime: uptime, countTraffic: true, capturedAt: now)
        let increments = result.increments.map {
            UsageIncrement(identity: $0.identity, uploadedBytes: $0.uploadedBytes, downloadedBytes: $0.downloadedBytes)
        }
        try await store.recordSample(day: day, increments: increments)
        await runtime.evaluateApplicationAlerts(increments, day: day, continuous: !result.rebaselined,
            pathGeneration: 7, generation: 0, now: now, uptime: uptime)
    }
    let rows = try await store.snapshot(day: day)
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.id == "exec:/Library/Application Support/clash-verge-service/cores/verge-mihomo")
    #expect(row.usage.uploadedBytes == 10_000_000)
    #expect(row.usage.downloadedBytes == 240_000_000)
    #expect(SystemProcessClassification(identity: row.identity).category == .sharedProxy)
    let events = try await store.trafficAlertEvents(day: day)
    #expect(events.count == 1)
    #expect(events.first?.kind == .applicationBurst)
    #expect(events.first?.sourceKey == row.id)
    #expect(events.first?.observedBytes == 250_000_000)
    #expect(try await store.interfaceUsage(day: day) == nil)
    try await store.close()
}
