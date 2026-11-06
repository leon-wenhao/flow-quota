import Foundation
import FlowQuotaCore
import FlowQuotaPlatform
import FlowQuotaStore
import Testing
@testable import FlowQuotaAgent

private final class CategoryCounter: InterfaceCounterReading, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: UInt64 = 0
    private var observation = NetworkObservation(state: .expensive, message: "simulated", generation: 1, interfaceIndexes: [4])
    func set(_ bytes: UInt64, _ state: NetworkState, generation: UInt64) {
        lock.withLock {
            self.bytes = bytes
            observation = NetworkObservation(state: state, message: "simulated", generation: generation, interfaceIndexes: [4])
        }
    }
    func path() -> NetworkObservation { lock.withLock { observation } }
    func read(interfaceIndex: UInt32) throws -> InterfaceCounterSnapshot {
        lock.withLock { InterfaceCounterSnapshot(interfaceIndex: interfaceIndex, uploadedBytes: 0, downloadedBytes: bytes) }
    }
}

private func withCategoryRuntime(_ body: (AgentRuntime, QuotaStore, CategoryCounter) async throws -> Void) async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try QuotaStore(path: folder.appendingPathComponent("quota.sqlite").path)
    let counter = CategoryCounter()
    let runtime = AgentRuntime(store: store, interfaceReader: counter, networkObservation: { counter.path() })
    try await body(runtime, store, counter)
    try await store.close()
}

@Test func networkSwitchesNeverMoveOrBridgeInterfaceCountersAndOrdinaryAlertsStartDisabled() async throws {
    try await withCategoryRuntime { runtime, store, counter in
        let day = try LocalDay.key(for: Date(), in: .current)
        func sample(_ bytes: UInt64, _ state: NetworkState, _ generation: UInt64, _ tick: UInt64) async {
            counter.set(bytes, state, generation: generation)
            await runtime.sampleInterface(path: counter.path(), generation: 0, uptime: tick * 1_000_000_000)
        }
        await sample(100, .expensive, 1, 1)
        await sample(250_000_100, .expensive, 1, 3)
        // Category is part of the interface scope even when the generation is
        // accidentally unchanged in an injected provider. No cross-scope delta.
        await sample(900_000_000, .ordinary, 1, 5)
        await sample(5_900_000_000, .ordinary, 1, 7)
        #expect(try await store.interfaceUsage(day: day)?.totalBytes == 250_000_000)
        #expect(try await store.interfaceUsage(day: day, category: .ordinary)?.totalBytes == 5_000_000_000)
        #expect(try await store.trafficAlertEvents(day: day).map(\.kind) == [.interfaceBurst])
        #expect(try await store.trafficAlertEvents(day: day, category: .ordinary).isEmpty)
        let snapshot = try await runtime.snapshot()
        #expect(snapshot.trafficCategories?.count == 2)
        #expect(snapshot.usage(for: .ordinary)?.interfaceUsage?.totalBytes == 5_000_000_000)
        #expect(snapshot.pendingTrafficAlerts.map(\.category) == [.metered])
        await sample(8_000_000_000, .hotspot, 2, 9)
        await sample(8_200_000_000, .hotspot, 2, 11)
        #expect(try await store.interfaceUsage(day: day)?.totalBytes == 450_000_000)
        #expect(try await store.interfaceUsage(day: day, category: .ordinary)?.totalBytes == 5_000_000_000)
        await sample(9_000_000_000, .unknown, 3, 13)
        await sample(12_000_000_000, .ordinary, 4, 15)
        #expect(try await store.interfaceUsage(day: day, category: .ordinary)?.totalBytes == 5_000_000_000)
    }
}

@Test func ordinaryBurstCanBeEnabledWithoutChangingMeteredPolicyOrSharingApplicationWindows() async throws {
    try await withCategoryRuntime { runtime, store, _ in
        let now = Date(), day = try LocalDay.key(for: Date(), in: .current)
        let app = AppIdentity(key: "exec:/category-source", name: "Source")
        let increments = [UsageIncrement(identity: app, uploadedBytes: 0, downloadedBytes: 250_000_000)]
        for category in TrafficCategory.allCases {
            try await store.recordSample(day: day, increments: increments, category: category)
        }
        await runtime.evaluateApplicationAlerts([], day: day, continuous: false, pathGeneration: 1,
            generation: 0, now: now, uptime: 1_000_000_000)
        await runtime.evaluateApplicationAlerts(increments, day: day, continuous: true, pathGeneration: 1,
            generation: 0, now: now, uptime: 3_000_000_000)
        await runtime.evaluateApplicationAlerts(increments, day: day, continuous: true, pathGeneration: 1,
            generation: 0, now: now, uptime: 5_000_000_000, category: .ordinary)
        #expect(try await store.trafficAlertEvents(day: day, category: .ordinary).isEmpty)
        let ordinary = try TrafficAlertPolicy(dailyInterfaceBytes: nil, interfaceBurstBytes: nil,
            applicationBurstBytes: 200_000_000, version: 2)
        _ = try await runtime.handle(.saveCategoryTrafficAlertPolicy(category: .ordinary, policy: ordinary))
        #expect(try await store.trafficAlertPolicy() == .initial)
        await runtime.evaluateApplicationAlerts([], day: day, continuous: false, pathGeneration: 1,
            generation: 0, now: now, uptime: 7_000_000_000, category: .ordinary)
        await runtime.evaluateApplicationAlerts(increments, day: day, continuous: true, pathGeneration: 1,
            generation: 0, now: now, uptime: 9_000_000_000, category: .ordinary)
        #expect(try await store.trafficAlertEvents(day: day).count == 1)
        #expect(try await store.trafficAlertEvents(day: day, category: .ordinary).count == 1)
        #expect(Set(try await runtime.snapshot().pendingTrafficAlerts.map(\.category)) == [.metered, .ordinary])
    }
}

extension AgentRuntime {
    fileprivate func categoryTestCollection() { monitoring = .collecting; sampledAt = Date() }
}

@Test func applicationDailyNoticesAndAcknowledgementsRemainIndependentAfterSwitch() async throws {
    try await withCategoryRuntime { runtime, store, _ in
        let day = try LocalDay.key(for: Date(), in: .current)
        let app = AppIdentity(key: "signed:category-reminder", name: "App")
        for category in TrafficCategory.allCases {
            try await store.recordSample(day: day, increments: [UsageIncrement(identity: app, uploadedBytes: 120, downloadedBytes: 0)], category: category)
            _ = try await runtime.handle(.saveCategoryRule(category: category, appKey: app.key, rule: QuotaRule(limitBytes: 100)))
        }
        await runtime.categoryTestCollection()
        let before = try await runtime.snapshot()
        #expect(Set(before.notifications.map { $0.key.category }) == [.metered, .ordinary])
        #expect(Set(before.notifications.map(\.id)).count == 2)
        let metered = try #require(before.notifications.first { $0.key.category == .metered })
        _ = try await runtime.handle(.acknowledgeNotification(metered.key))
        #expect(try await runtime.snapshot().notifications.map { $0.key.category } == [.ordinary])
    }
}

@Test func savingInactiveCategoryPolicyDoesNotEraseActiveBurstWindow() async throws {
    try await withCategoryRuntime { runtime, store, _ in
        let now = Date(), day = try LocalDay.key(for: Date(), in: .current)
        let increment = UsageIncrement(identity: AppIdentity(key: "exec:/active", name: "Active"),
            uploadedBytes: 120_000_000, downloadedBytes: 0)
        try await store.recordSample(day: day, increments: [increment])
        await runtime.evaluateApplicationAlerts([], day: day, continuous: false, pathGeneration: 1,
            generation: 0, now: now, uptime: 1_000_000_000)
        await runtime.evaluateApplicationAlerts([increment], day: day, continuous: true, pathGeneration: 1,
            generation: 0, now: now, uptime: 3_000_000_000)
        #expect(try await store.trafficAlertEvents(day: day).isEmpty)
        _ = try await runtime.handle(.saveCategoryTrafficAlertPolicy(category: .ordinary,
            policy: TrafficAlertPolicy(dailyInterfaceBytes: nil, interfaceBurstBytes: nil,
                applicationBurstBytes: nil, version: 2)))
        await runtime.evaluateApplicationAlerts([increment], day: day, continuous: true, pathGeneration: 1,
            generation: 0, now: now, uptime: 5_000_000_000)
        #expect(try await store.trafficAlertEvents(day: day).first?.observedBytes == 240_000_000)
        #expect(try await store.trafficAlertEvents(day: day, category: .ordinary).isEmpty)
    }
}
