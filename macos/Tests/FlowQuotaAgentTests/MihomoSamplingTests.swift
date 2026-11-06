import Foundation
import Testing
import FlowQuotaCore
@testable import FlowQuotaPlatform
@testable import FlowQuotaStore
@testable import FlowQuotaAgent

private final class MihomoSamplingFixture: InterfaceCounterReading, @unchecked Sendable {
    private let lock = NSLock()
    private var observation = NetworkObservation(state: .expensive, message: "simulated", generation: 7, interfaceIndexes: [4])
    private var uptime: UInt64 = 1
    private var payload = Data()
    private var failing = false
    private var physicalReads = 0
    private var requests = 0
    let origin = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3_600)

    var controller: MihomoControllerClient {
        MihomoControllerClient(request: { [self] endpoint in
            try lock.withLock {
                requests += 1
                #expect(endpoint == "/connections")
                if failing { throw PlatformError.unavailable("mock controller failure") }
                return payload
            }
        })
    }
    var readCount: Int { lock.withLock { physicalReads } }
    var requestCount: Int { lock.withLock { requests } }
    func path() -> NetworkObservation { lock.withLock { observation } }
    func clock() -> UInt64 { lock.withLock { uptime } }
    func setPath(_ state: NetworkState, generation: UInt64 = 7) {
        lock.withLock {
            observation = NetworkObservation(state: state, message: "simulated", generation: generation, interfaceIndexes: [4])
        }
    }
    func read(interfaceIndex: UInt32) throws -> InterfaceCounterSnapshot {
        lock.withLock { physicalReads += 1 }
        throw InterfaceCounterError.interfaceUnavailable(interfaceIndex)
    }

    func feed(_ total: Int64, at seconds: UInt64, to runtime: AgentRuntime,
              generation: UInt64 = 0, requestScope: String? = nil, closed: Bool = false,
              capturedAt: Date? = nil) async throws {
        let connections: [[String: Any]] = closed ? [] : [
            ["id": "a", "upload": total, "download": total * 2,
             "metadata": ["processPath": "/mihomo-regression/Client", "host": "youtube.com"], "chains": []]]
        let json: [String: Any] = ["uploadTotal": total, "downloadTotal": total * 2, "connections": connections]
        let data = try JSONSerialization.data(withJSONObject: json)
        lock.withLock { payload = data; uptime = seconds * 1_000_000_000 + 1; failing = false }
        try await runtime.ingestMihomo(controller.readConnections(), generation: generation,
            capturedAt: capturedAt ?? origin.addingTimeInterval(Double(seconds)), requestScope: requestScope)
    }

    func fail(_ runtime: AgentRuntime, generation: UInt64 = 0) async {
        lock.withLock { failing = true }
        do {
            _ = try controller.readConnections()
            Issue.record("Injected controller failure unexpectedly succeeded")
        } catch {
            await runtime.mihomoSamplingFailed(error, generation: generation)
        }
    }
}

extension QuotaStore {
    // Same-connection changes catch even writes that leave the final bytes unchanged.
    fileprivate func mihomoTestChangeCount() throws -> Int64 { try database.scalar("SELECT total_changes()") }
}

struct MihomoSamplingTests {
    private func withRuntime(seedLedgers: Bool = false,
                             _ body: (AgentRuntime, QuotaStore, MihomoSamplingFixture) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try QuotaStore(path: folder.appendingPathComponent("quota.sqlite").path)
        let fixture = MihomoSamplingFixture()
        let runtime = AgentRuntime(store: store, interfaceReader: fixture,
            networkObservation: { fixture.path() }, samplingTime: { fixture.clock() }, mihomoController: fixture.controller)
        do {
            let day = try LocalDay.key(for: fixture.origin, in: .current)
            if seedLedgers {
                for category in TrafficCategory.allCases {
                    let bytes: Int64 = category == .metered ? 11 : 33
                    try await store.recordSample(day: day, increments: [UsageIncrement(
                        identity: AppIdentity(key: "exec:/nettop-existing", name: "Existing nettop source"),
                        uploadedBytes: bytes, downloadedBytes: bytes * 2)],
                        interfaceIncrement: InterfaceUsage(day: day, uploadedBytes: bytes * 10, downloadedBytes: bytes * 20),
                        category: category, interfaceObservedAt: fixture.origin)
                }
            }
            let changes = try await store.mihomoTestChangeCount()
            try await body(runtime, store, fixture)
            #expect(fixture.readCount == 0)
            #expect(try await store.mihomoTestChangeCount() == changes)
            #expect(await runtime.sampler == nil)
            #expect(await runtime.samplingTask == nil)
            #expect(await runtime.interfaceTask == nil)
            #expect(await runtime.mihomoTask == nil)
            if !seedLedgers {
                for category in TrafficCategory.allCases {
                    #expect(try await !store.hasApplicationUsage(day: day, category: category))
                    #expect(try await store.snapshot(day: day, category: category).isEmpty)
                    #expect(try await store.interfaceUsage(day: day, category: category) == nil)
                    #expect(try await store.interfaceUsageMinutes(day: day, category: category).isEmpty)
                }
            }
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test func failuresPreserveConfirmedBytesAndRecoveryStartsAtANewBaseline() async throws {
        try await withRuntime { runtime, _, fixture in
            await fixture.fail(runtime)
            #expect(await runtime.mihomoProxy.status == .unavailable)
            #expect(await runtime.mihomoProxy.sampledAt == nil)
            try await fixture.feed(100, at: 0, to: runtime)
            try await fixture.feed(110, at: 2, to: runtime)
            let earned = await runtime.mihomoProxy
            #expect(earned.totalBytes == 30)
            #expect(earned.sources.first?.totalBytes == 30)
            for _ in 0..<2 {
                await fixture.fail(runtime)
                let failed = await runtime.mihomoProxy
                #expect(failed.status == .stale)
                #expect(failed.uploadedBytes == earned.uploadedBytes)
                #expect(failed.downloadedBytes == earned.downloadedBytes)
                #expect(failed.sources == earned.sources)
                #expect(failed.sampledAt == earned.sampledAt)
                #expect(failed.day == earned.day && failed.category == earned.category)
                #expect(failed.message.contains("mock controller failure"))
            }
            try await fixture.feed(9_000, at: 4, to: runtime)
            #expect(await runtime.mihomoProxy.status == .observing)
            #expect(await runtime.mihomoProxy.totalBytes == 30)
            try await fixture.feed(9_005, at: 6, to: runtime)
            #expect(await runtime.mihomoProxy.uploadedBytes == 15)
            #expect(await runtime.mihomoProxy.downloadedBytes == 30)
            #expect(await runtime.mihomoProxy.sources.first?.totalBytes == 45)
        }
    }

    @Test func pausePreservesAttributionAndDropsTheUnobservedInterval() async throws {
        try await withRuntime { runtime, _, fixture in
            try await fixture.feed(100, at: 0, to: runtime)
            try await fixture.feed(110, at: 2, to: runtime)
            let earned = await runtime.mihomoProxy
            await runtime.pauseMihomoSampling()
            let paused = await runtime.mihomoProxy
            #expect(paused.status == .paused)
            #expect(paused.sources == earned.sources)
            #expect(paused.totalBytes == earned.totalBytes)
            #expect(paused.sampledAt == earned.sampledAt)
            #expect(paused.activeConnectionCount == 0)
            try await fixture.feed(8_000, at: 4, to: runtime)
            #expect(await runtime.mihomoProxy.totalBytes == 30)
            try await fixture.feed(8_002, at: 6, to: runtime)
            #expect(await runtime.mihomoProxy.totalBytes == 36)
            #expect(await runtime.mihomoProxy.sources.first?.totalBytes == 36)
        }
    }

    @Test func stopInvalidatesGenerationPreservesBytesAndRejectsLateSuccessAndFailure() async throws {
        try await withRuntime { runtime, _, fixture in
            try await fixture.feed(100, at: 0, to: runtime)
            try await fixture.feed(110, at: 2, to: runtime)
            let earned = await runtime.mihomoProxy
            let generation = await runtime.samplingGeneration
            await runtime.stopMonitoring()
            #expect(await runtime.samplingGeneration == generation + 1)
            #expect(await runtime.monitoring == .paused)
            let paused = await runtime.mihomoProxy
            #expect(paused.status == .paused)
            #expect(paused.sources == earned.sources)
            #expect(paused.uploadedBytes == earned.uploadedBytes)
            #expect(paused.downloadedBytes == earned.downloadedBytes)
            #expect(paused.sampledAt == earned.sampledAt)
            try await fixture.feed(9_000, at: 4, to: runtime, generation: generation)
            await fixture.fail(runtime, generation: generation)
            #expect(await runtime.mihomoProxy == paused)
            let snapshot = try await runtime.snapshot()
            #expect(snapshot.monitoring == .paused)
            #expect(snapshot.samplingEnabled == false)
            #expect(snapshot.mihomoProxy == paused)
            #expect(snapshot.usage(for: .metered)?.mihomoProxy?.status == .paused)
            #expect(snapshot.usage(for: .metered)?.mihomoProxy?.sources == earned.sources)
            #expect(snapshot.usage(for: .metered)?.mihomoProxy?.totalBytes == 30)
            try await fixture.feed(10_000, at: 6, to: runtime, generation: generation + 1)
            #expect(await runtime.mihomoProxy.totalBytes == 30)
            try await fixture.feed(10_005, at: 8, to: runtime, generation: generation + 1)
            #expect(await runtime.mihomoProxy.totalBytes == 45)
        }
    }

    @Test func staleGenerationCannotCommitOrResetTheCurrentBaseline() async throws {
        try await withRuntime { runtime, _, fixture in
            try await fixture.feed(100, at: 0, to: runtime)
            try await fixture.feed(110, at: 2, to: runtime)
            let earned = await runtime.mihomoProxy
            try await fixture.feed(9_000, at: 3, to: runtime, generation: 99)
            await fixture.fail(runtime, generation: 99)
            #expect(await runtime.mihomoProxy == earned)
            try await fixture.feed(115, at: 4, to: runtime)
            #expect(await runtime.mihomoProxy.totalBytes == 45)
            #expect(await runtime.mihomoProxy.sources.first?.totalBytes == 45)
        }
    }

    @Test func responseSpanningAPathChangeIsDiscardedAndRecoveryRebaselines() async throws {
        try await withRuntime { runtime, _, fixture in
            try await fixture.feed(100, at: 0, to: runtime)
            try await fixture.feed(110, at: 2, to: runtime)
            let earned = await runtime.mihomoProxy
            let day = try LocalDay.key(for: fixture.origin, in: .current)
            fixture.setPath(.ordinary, generation: 8)
            try await fixture.feed(5_000, at: 4, to: runtime, requestScope: "\(day):7:expensive")
            #expect(await runtime.mihomoProxy == earned)
            #expect(try await runtime.snapshot().usage(for: .ordinary)?.mihomoProxy?.sampledAt == nil)
            try await fixture.feed(8_000, at: 6, to: runtime, requestScope: "\(day):8:ordinary")
            #expect(await runtime.mihomoProxy.totalBytes == 0)
            try await fixture.feed(8_005, at: 8, to: runtime, requestScope: "\(day):8:ordinary")
            #expect(await runtime.mihomoProxy.totalBytes == 15)
            #expect(try await runtime.snapshot().usage(for: .metered)?.mihomoProxy?.totalBytes == 30)
        }
    }

    @Test func categorySnapshotsSeparateProxyBytesAndLeaveNettopAndInterfaceLedgersUntouched() async throws {
        try await withRuntime(seedLedgers: true) { runtime, store, fixture in
            let day = try LocalDay.key(for: fixture.origin, in: .current)
            try await fixture.feed(100, at: 0, to: runtime)
            try await fixture.feed(110, at: 2, to: runtime, closed: false)
            fixture.setPath(.ordinary)
            try await fixture.feed(1_000, at: 4, to: runtime)
            try await fixture.feed(1_020, at: 6, to: runtime)
            fixture.setPath(.unknown)
            try await fixture.feed(5_000, at: 8, to: runtime)
            try await fixture.feed(7_000, at: 10, to: runtime)
            #expect(await runtime.mihomoProxy.category == nil)
            #expect(await runtime.mihomoProxy.sources.isEmpty)
            #expect(await runtime.mihomoProxy.totalBytes == 0)
            fixture.setPath(.hotspot, generation: 9)
            try await fixture.feed(8_000, at: 12, to: runtime)
            try await fixture.feed(8_005, at: 14, to: runtime)
            let requests = fixture.requestCount
            let snapshot = try await runtime.snapshot()
            #expect(fixture.requestCount == requests)
            #expect(snapshot.network == .hotspot)
            #expect(snapshot.mihomoProxy?.category == .metered)
            for category in TrafficCategory.allCases {
                let data = try #require(snapshot.usage(for: category))
                let proxy = try #require(data.mihomoProxy)
                let observed: Int64 = category == .metered ? 15 : 20
                let durable: Int64 = category == .metered ? 11 : 33
                #expect(proxy.day == day && proxy.category == category)
                #expect(proxy.uploadedBytes == observed)
                #expect(proxy.downloadedBytes == observed * 2)
                #expect(proxy.sources.count == 1)
                #expect(proxy.sources.first?.uploadedBytes == observed)
                #expect(proxy.sources.first?.downloadedBytes == observed * 2)
                #expect(data.applications.count == 1)
                #expect(data.applications.first?.id == "exec:/nettop-existing")
                #expect(data.applications.first?.usage.totalBytes == durable * 3)
                #expect(data.interfaceUsage?.totalBytes == durable * 30)
                #expect(data.interfaceUsageMinutes?.first?.uploadedBytes == durable * 10)
                #expect(data.interfaceUsageMinutes?.first?.downloadedBytes == durable * 20)
                #expect(try await store.interfaceUsage(day: day, category: category) == data.interfaceUsage)
            }
        }
    }
}
