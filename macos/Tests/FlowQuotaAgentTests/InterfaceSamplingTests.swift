import Foundation
import Testing
import FlowQuotaCore
import FlowQuotaPlatform
import FlowQuotaStore
@testable import FlowQuotaAgent

private final class InterfaceFixture: @unchecked Sendable, InterfaceCounterReading {
    private let lock = NSLock()
    private var observation = NetworkObservation(state: .expensive, message: "test", generation: 1,
                                                  interfaceIndexes: [4])
    private var counters: [InterfaceCounterSnapshot?]
    private var reads = 0
    var changesPathDuringRead = false

    init(_ counters: [InterfaceCounterSnapshot?]) { self.counters = counters }
    func path() -> NetworkObservation {
        lock.lock(); defer { lock.unlock() }
        return observation
    }
    func update(_ path: NetworkObservation) {
        lock.lock(); defer { lock.unlock() }
        observation = path
    }
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    func read(interfaceIndex: UInt32) throws -> InterfaceCounterSnapshot {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        if changesPathDuringRead {
            observation = NetworkObservation(state: .expensive, message: "changed", generation: 99,
                                             interfaceIndexes: [4])
        }
        guard !counters.isEmpty, let value = counters.removeFirst() else {
            throw InterfaceCounterError.interfaceUnavailable(interfaceIndex)
        }
        return value
    }
}

private func count(_ up: UInt64, _ down: UInt64) -> InterfaceCounterSnapshot {
    InterfaceCounterSnapshot(interfaceIndex: 4, uploadedBytes: up, downloadedBytes: down)
}

@Test func interfaceTotalsPersistSeparatelyFromApplicationAttributionAndSurviveRestart() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try QuotaStore(path: folder.appendingPathComponent("quota.sqlite").path)
    let fixture = InterfaceFixture([count(100, 200), count(130, 270)])
    let runtime = AgentRuntime(store: store, interfaceReader: fixture,
                               networkObservation: { fixture.path() })
    let day = try LocalDay.key(for: Date(), in: .current)
    try await store.recordSample(day: day, increments: [UsageIncrement(
        identity: AppIdentity(key: "app:/Proxy.app", name: "Proxy"),
        uploadedBytes: 9000, downloadedBytes: 9000)])
    #expect(try await store.interfaceUsage(day: day) == nil)
    let yesterday = try LocalDay.key(for: Date().addingTimeInterval(-86_400), in: .current)
    try await store.recordSample(day: yesterday, increments: [], interfaceIncrement:
        InterfaceUsage(day: yesterday, uploadedBytes: 40, downloadedBytes: 60))
    await runtime.sampleInterface(path: fixture.path(), generation: 0, uptime: 1_000_000_000)
    #expect(try await store.interfaceUsage(day: day)?.totalBytes == 0) // Baseline only.
    #expect(try await store.interfaceUsage(day: yesterday) == nil)
    await runtime.sampleInterface(path: fixture.path(), generation: 0, uptime: 3_000_000_000)
    #expect(try await store.interfaceUsage(day: day)?.totalBytes == 100)
    let snapshot = try await runtime.snapshot()
    #expect(snapshot.interfaceUsage?.uploadedBytes == 30)
    #expect(snapshot.interfaceUsage?.downloadedBytes == 70)
    #expect(snapshot.applications.first?.usage.totalBytes == 18000)
    #expect(snapshot.interfaceSampledAt != nil)
    // No process sampler has run: the interface meter works independently.
    #expect(snapshot.sampledAt == nil)
    let restarted = AgentRuntime(store: store, interfaceReader: InterfaceFixture([count(9999, 9999)]),
                                 networkObservation: { fixture.path() })
    await restarted.sampleInterface(path: fixture.path(), generation: 0, uptime: 5_000_000_000)
    #expect(try await store.interfaceUsage(day: day)?.totalBytes == 100)
    try await store.close()
}

@Test func interfaceReadFailureCreatesUnknownGapWithoutBackfillingOrStoppingAppLedger() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try QuotaStore(path: folder.appendingPathComponent("quota.sqlite").path)
    let fixture = InterfaceFixture([count(100, 100), count(110, 120), nil,
                                    count(900, 900), count(905, 910)])
    let runtime = AgentRuntime(store: store, interfaceReader: fixture,
                               networkObservation: { fixture.path() })
    let day = try LocalDay.key(for: Date(), in: .current)
    for tick in 1...5 {
        await runtime.sampleInterface(path: fixture.path(), generation: 0,
                                      uptime: UInt64(tick) * 2_000_000_000)
        if tick == 3 {
            let snapshot = try await runtime.snapshot()
            #expect(snapshot.interfaceUsage?.totalBytes == 30)
            #expect(snapshot.interfaceSampledAt == nil)
            #expect(snapshot.interfaceMessage.contains("暂不可用"))
        }
    }
    #expect(try await store.interfaceUsage(day: day)?.totalBytes == 45)
    #expect(try await store.snapshot(day: day).isEmpty)
    try await store.close()
}

@Test func ordinaryAmbiguousAndStoppedInterfaceMetersNeverReadSystemCounters() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try QuotaStore(path: folder.appendingPathComponent("quota.sqlite").path)
    let fixture = InterfaceFixture([])
    let runtime = AgentRuntime(store: store, interfaceReader: fixture,
                               networkObservation: { fixture.path() })
    for path in [NetworkObservation(state: .ordinary, message: "", interfaceIndexes: [4]),
                 NetworkObservation(state: .expensive, message: "", interfaceIndexes: [4, 5]),
                 NetworkObservation(state: .expensive, message: "", interfaceIndexes: [])] {
        fixture.update(path)
        await runtime.sampleInterface(path: path, generation: 0)
    }
    #expect(fixture.readCount == 0)
    _ = try await runtime.handle(.stopProtection)
    await runtime.sampleInterface(path: NetworkObservation(state: .expensive, message: "",
                                  interfaceIndexes: [4]), generation: 0)
    #expect(fixture.readCount == 0)
    let day = try LocalDay.key(for: Date(), in: .current)
    #expect(try await store.interfaceUsage(day: day) == nil)
    try await store.close()
}

@Test func networkChangeDuringCounterReadDiscardsTheUncertainSample() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try QuotaStore(path: folder.appendingPathComponent("quota.sqlite").path)
    let fixture = InterfaceFixture([count(100, 200)])
    fixture.changesPathDuringRead = true
    let runtime = AgentRuntime(store: store, interfaceReader: fixture,
                               networkObservation: { fixture.path() })
    let pathBeforeRead = fixture.path()
    await runtime.sampleInterface(path: pathBeforeRead, generation: 0)
    let day = try LocalDay.key(for: Date(), in: .current)
    #expect(try await store.interfaceUsage(day: day) == nil)
    let snapshot = try await runtime.snapshot()
    #expect(snapshot.interfaceSampledAt == nil)
    #expect(snapshot.interfaceMessage.contains("网络发生变化"))
    try await store.close()
}

@Test func stoppingTheIndependentInterfaceTaskCancelsItsNextTick() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try QuotaStore(path: folder.appendingPathComponent("quota.sqlite").path)
    let fixture = InterfaceFixture([count(100, 200)])
    let runtime = AgentRuntime(store: store, interfaceReader: fixture,
                               networkObservation: { fixture.path() })
    await runtime.startInterfaceSampling(generation: 0)
    let deadline = ContinuousClock.now + .seconds(1)
    while fixture.readCount == 0, ContinuousClock.now < deadline { await Task.yield() }
    #expect(fixture.readCount == 1)
    _ = try await runtime.handle(.stopProtection)
    #expect(await runtime.interfaceTask == nil)
    #expect(fixture.readCount == 1)
    #expect(await runtime.interfaceMessage.contains("已暂停"))
    try await store.close()
}
