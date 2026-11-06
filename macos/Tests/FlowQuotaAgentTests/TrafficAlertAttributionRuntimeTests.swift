import Foundation
import FlowQuotaCore
import FlowQuotaPlatform
import FlowQuotaStore
import Testing
@testable import FlowQuotaAgent

private func withAttributionRuntime(_ body: (AgentRuntime, QuotaStore, String, Date) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try QuotaStore(path: directory.appendingPathComponent("quota.sqlite").path)
    let path = NetworkObservation(state: .expensive, message: "simulated", generation: 7, interfaceIndexes: [4])
    let runtime = AgentRuntime(store: store, networkObservation: { path })
    let now = Date()
    try await body(runtime, store, LocalDay.key(for: now, in: .current), now)
    try await store.close()
}

@Test func interfaceSnapshotWorksWithApplicationAlertsDisabledAndOnlyDetailsCarryFullEvidence() async throws {
    try await withAttributionRuntime { runtime, store, day, now in
        let policy = try TrafficAlertPolicy(dailyInterfaceBytes: nil, interfaceBurstBytes: 100,
            applicationBurstBytes: nil, windowSeconds: 180, cooldownSeconds: 600, version: 2)
        try await store.saveTrafficAlertPolicy(policy)
        let increments = [UsageIncrement(identity: AppIdentity(key: "signed:browser", name: "Browser"),
            uploadedBytes: 30, downloadedBytes: 90)]
        await runtime.evaluateApplicationAlerts([], day: day, continuous: false, pathGeneration: 7,
            generation: 0, now: now, uptime: 1_000_000_000)
        await runtime.evaluateApplicationAlerts(increments, day: day, continuous: true, pathGeneration: 7,
            generation: 0, now: now, uptime: 3_000_000_000)
        await runtime.evaluateInterfaceAlerts(day: day, uploaded: 0, downloaded: 0, continuous: false,
            pathGeneration: 7, generation: 0, now: now, uptime: 1_000_000_000)
        await runtime.evaluateInterfaceAlerts(day: day, uploaded: 0, downloaded: 200, continuous: true,
            pathGeneration: 7, generation: 0, now: now, uptime: 3_000_000_000)
        let events = try await store.trafficAlertEvents(day: day)
        let alert = try #require(events.first)
        #expect(events.count == 1 && alert.kind == .interfaceBurst)
        #expect(alert.applications?.items.first?.uploadedBytes == 30)
        #expect(alert.applications?.items.first?.downloadedBytes == 90)
        let snapshot = try await runtime.snapshot()
        #expect(snapshot.trafficAlertEvents.first?.applications == nil)
        #expect(snapshot.trafficAlertEvents.first?.applicationSummary == "Browser")
        guard case .trafficAlertHistory(let page) = try await runtime.handle(.categoryTrafficAlertHistory(
            category: .metered, day: day, offset: 0)) else { Issue.record("Wrong reply"); return }
        #expect(page.first?.applications == nil)
        guard case .trafficAlertDetails(let details) = try await runtime.handle(.trafficAlertDetails(
            category: .metered, day: day, id: alert.id)) else { Issue.record("Wrong reply"); return }
        #expect(details.applications == alert.applications)
        do {
            _ = try await runtime.handle(.trafficAlertDetails(category: .ordinary, day: day, id: alert.id))
            Issue.record("Cross-category access must fail")
        } catch {}
    }
}

@Test func applicationAlertFreezesOnlyTriggeringApplicationAndInterfaceAlertSurvivesMissingAttribution() async throws {
    try await withAttributionRuntime { runtime, store, day, now in
        let identity = AppIdentity(key: "signed:browser", name: "Browser")
        try await store.recordSample(day: day, increments: [UsageIncrement(identity: identity, uploadedBytes: 0, downloadedBytes: 0)])
        let deltas = [UsageIncrement(identity: identity, uploadedBytes: 50_000_000, downloadedBytes: 160_000_000),
            UsageIncrement(identity: AppIdentity(key: "signed:chat", name: "Chat"), uploadedBytes: 2, downloadedBytes: 3)]
        await runtime.evaluateApplicationAlerts([], day: day, continuous: false, pathGeneration: 7,
            generation: 0, now: now, uptime: 1_000_000_000)
        await runtime.evaluateApplicationAlerts(deltas, day: day, continuous: true, pathGeneration: 7,
            generation: 0, now: now, uptime: 3_000_000_000)
        let appAlert = try #require(try await store.trafficAlertEvents(day: day).first)
        #expect(appAlert.applications?.items.count == 1)
        #expect(appAlert.applications?.items.first?.totalBytes == 210_000_000)
        // A new path has no application evidence; interface alert remains independent.
        await runtime.evaluateInterfaceAlerts(day: day, uploaded: 0, downloaded: 0, continuous: false,
            pathGeneration: 8, generation: 0, now: now, uptime: 4_000_000_000)
        await runtime.evaluateInterfaceAlerts(day: day, uploaded: 0, downloaded: 250_000_000, continuous: true,
            pathGeneration: 8, generation: 0, now: now, uptime: 6_000_000_000)
        let events = try await store.trafficAlertEvents(day: day)
        let interfaceAlert = try #require(events.first { $0.kind == .interfaceBurst })
        #expect(interfaceAlert.applications?.observedAt == nil)
        #expect(interfaceAlert.applications?.notice != nil)
    }
}
