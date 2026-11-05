import Foundation
import FlowQuotaCore
import FlowQuotaPlatform
import FlowQuotaStore
import Testing
@testable import FlowQuotaAgent

private final class AlertCounter: InterfaceCounterReading, @unchecked Sendable {
    private let lock = NSLock()
    private var total: UInt64 = 0
    func set(_ bytes: UInt64) { lock.lock(); defer { lock.unlock() }; total = bytes }
    func read(interfaceIndex: UInt32) throws -> InterfaceCounterSnapshot {
        lock.lock(); defer { lock.unlock() }
        return InterfaceCounterSnapshot(interfaceIndex: interfaceIndex, uploadedBytes: 0, downloadedBytes: total)
    }
}

private func withAlertRuntime(_ body: (AgentRuntime, QuotaStore, AlertCounter, NetworkObservation) async throws -> Void) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try QuotaStore(path: dir.appendingPathComponent("quota.sqlite").path)
    let counter = AlertCounter()
    let path = NetworkObservation(state: .expensive, message: "simulated", generation: 7, interfaceIndexes: [4])
    let runtime = AgentRuntime(store: store, interfaceReader: counter, networkObservation: { path })
    try await body(runtime, store, counter, path)
    try await store.close()
}

@Test func twelveGigabyteUnknownDownloadRaisesInterfaceAlertsWithoutApplicationSampling() async throws {
    try await withAlertRuntime { runtime, store, counter, path in
        let now = Date()
        let day = try LocalDay.key(for: now, in: .current)
        await runtime.sampleInterface(path: path, generation: 0, now: now, uptime: 1_000_000_000)
        counter.set(12_000_000_000)
        await runtime.sampleInterface(path: path, generation: 0, now: now, uptime: 3_000_000_000)
        let events = try await store.trafficAlertEvents(day: day)
        #expect(Set(events.map(\.kind)) == [.dailyInterface, .interfaceBurst])
        #expect(events.allSatisfy { $0.observedBytes == 12_000_000_000 && $0.sourceKey.isEmpty })
        #expect(events.first(where: { $0.kind == .interfaceBurst })?.observedSeconds == 2)
        #expect(try await store.snapshot(day: day).isEmpty)
        let snapshot = try await runtime.snapshot()
        #expect(snapshot.pendingTrafficAlerts.count == 2)
        #expect(snapshot.sampledAt == nil)
        counter.set(12_100_000_000)
        await runtime.sampleInterface(path: path, generation: 0, now: now, uptime: 5_000_000_000)
        #expect(try await store.trafficAlertEvents(day: day).count == 2)
    }
}

@Test func attributedApplicationAlertDoesNotInventAnInterfaceTotal() async throws {
    try await withAlertRuntime { runtime, store, _, _ in
        let now = Date()
        let day = try LocalDay.key(for: now, in: .current)
        let identity = AppIdentity(key: "exec:/usr/libexec/nsurlsessiond", name: "nsurlsessiond")
        let increments = [UsageIncrement(identity: identity, uploadedBytes: 0, downloadedBytes: 250_000_000)]
        await runtime.evaluateApplicationAlerts([], day: day, continuous: false, pathGeneration: 7,
            generation: 0, now: now, uptime: 1_000_000_000)
        try await store.recordSample(day: day, increments: increments)
        await runtime.evaluateApplicationAlerts(increments, day: day, continuous: true, pathGeneration: 7,
            generation: 0, now: now, uptime: 3_000_000_000)
        let event = try #require(try await store.trafficAlertEvents(day: day).first)
        #expect(event.kind == .applicationBurst)
        #expect(event.sourceKey == identity.key)
        #expect(event.sourceName == "nsurlsessiond")
        #expect(try await store.interfaceUsage(day: day) == nil)
        _ = try await runtime.handle(.acknowledgeTrafficAlert(id: event.id))
        #expect(try await runtime.snapshot().pendingTrafficAlerts.isEmpty)
        #expect(try await store.trafficAlertEvents(day: day).first?.scheduledAt != nil)
    }
}

@Test func savingDisabledPolicyAndPauseClearWindowsAndSuppressQueuedDelivery() async throws {
    try await withAlertRuntime { runtime, store, counter, path in
        let now = Date()
        let day = try LocalDay.key(for: now, in: .current)
        await runtime.sampleInterface(path: path, generation: 0, now: now, uptime: 1_000_000_000)
        counter.set(250_000_000)
        await runtime.sampleInterface(path: path, generation: 0, now: now, uptime: 3_000_000_000)
        #expect(try await runtime.snapshot().pendingTrafficAlerts.count == 1)
        _ = try await runtime.handle(.saveTrafficAlertPolicy(try TrafficAlertPolicy(dailyInterfaceBytes: nil,
            interfaceBurstBytes: nil, applicationBurstBytes: nil, version: 2)))
        #expect(try await runtime.snapshot().pendingTrafficAlerts.isEmpty)
        #expect(try await store.trafficAlertEvents(day: day).count == 1) // Evidence survives disabling.
        _ = try await runtime.handle(.stopProtection)
        counter.set(12_000_000_000)
        await runtime.sampleInterface(path: path, generation: 0, now: now, uptime: 5_000_000_000)
        #expect(try await store.interfaceUsage(day: day)?.totalBytes == 250_000_000)
        #expect(try await runtime.snapshot().pendingTrafficAlerts.isEmpty)
    }
}

@Test func applicationAlertsResetAfterUnknownGapAndDoNotBorrowFromOtherApplications() async throws {
    try await withAlertRuntime { runtime, store, _, _ in
        let now = Date()
        let day = try LocalDay.key(for: now, in: .current)
        let first = AppIdentity(key: "exec:/one", name: "one")
        let second = AppIdentity(key: "exec:/two", name: "two")
        let deltas = [UsageIncrement(identity: first, uploadedBytes: 0, downloadedBytes: 120_000_000),
                      UsageIncrement(identity: second, uploadedBytes: 0, downloadedBytes: 120_000_000)]
        try await store.recordSample(day: day, increments: deltas)
        for (tick, continuous) in [(1, false), (3, true), (20, true), (22, true)] {
            await runtime.evaluateApplicationAlerts(deltas, day: day, continuous: continuous, pathGeneration: 7,
                generation: 0, now: now, uptime: UInt64(tick) * 1_000_000_000)
        }
        #expect(try await store.trafficAlertEvents(day: day).isEmpty)
    }
}

@Test func applicationSourceLimitDoesNotStopIndependentInterfaceAlerting() async throws {
    try await withAlertRuntime { runtime, store, counter, path in
        let now = Date()
        let day = try LocalDay.key(for: now, in: .current)
        let deltas = (0..<129).map {
            UsageIncrement(identity: AppIdentity(key: "exec:/source-\($0)", name: "source \($0)"),
                           uploadedBytes: 0, downloadedBytes: 250_000_000)
        }
        await runtime.evaluateApplicationAlerts([], day: day, continuous: false, pathGeneration: 7,
            generation: 0, now: now, uptime: 1_000_000_000)
        await runtime.evaluateApplicationAlerts(deltas, day: day, continuous: true, pathGeneration: 7,
            generation: 0, now: now, uptime: 3_000_000_000)
        await runtime.sampleInterface(path: path, generation: 0, now: now, uptime: 1_000_000_000)
        counter.set(250_000_000)
        await runtime.sampleInterface(path: path, generation: 0, now: now, uptime: 3_000_000_000)
        let snapshot = try await runtime.snapshot()
        #expect(snapshot.trafficAlertMessage.contains("覆盖不完整"))
        #expect(snapshot.pendingTrafficAlerts.map(\.kind) == [.interfaceBurst])
        #expect(try await store.interfaceUsage(day: day)?.totalBytes == 250_000_000)
    }
}
