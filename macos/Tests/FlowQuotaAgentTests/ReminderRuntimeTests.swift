import Foundation
import FlowQuotaCore
import FlowQuotaStore
import Testing
@testable import FlowQuotaAgent

@Test func reminderSaveACKPersistsWithoutFilterAndInvalidNotificationCannotBeAcknowledged() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try QuotaStore(path: folder.appendingPathComponent("test.sqlite").path)
    let runtime = AgentRuntime(store: store)
    let app = AppIdentity(key: "app:/Example.app", name: "Example")
    try await store.registerApplication(app)
    let rule = try QuotaRule(limitBytes: 100)
    guard case .acknowledged = try await runtime.handle(.saveRule(appKey: app.key, rule: rule)) else {
        Issue.record("Expected persistent reminder configuration ACK")
        return
    }
    #expect(try await store.loadRules()[app.key] == rule)
    let day = try LocalDay.key(for: Date(), in: .current)
    let key = QuotaNotificationKey(identity: try QuotaIdentity(appKey: app.key, day: day, ruleVersion: 1),
                                   kind: .blocked)
    await #expect(throws: (any Error).self) {
        try await runtime.handle(.acknowledgeNotification(key))
    }
    #expect(try await store.deliveredNotifications(day: day).isEmpty)
    try await store.recordUsage(appKey: app.key, day: day, uploadedBytes: 101, downloadedBytes: 0)
    await runtime.publishSampleForTesting()
    guard case .snapshot(let pending) = try await runtime.handle(.snapshot) else {
        Issue.record("Expected reminder snapshot")
        return
    }
    // Persisted hotspot usage remains eligible even if the current path is ordinary/unknown.
    #expect(pending.notifications.count == 1)
    #expect(pending.notifications.first?.key == key)
    #expect(pending.readiness == .notInstalled)
    _ = try await runtime.handle(.acknowledgeNotification(key))
    _ = try await runtime.handle(.acknowledgeNotification(key))
    #expect(try await store.deliveredNotifications(day: day) == [key])
    _ = try await runtime.handle(.stopProtection)
    guard case .snapshot(let snapshot) = try await runtime.handle(.snapshot) else {
        Issue.record("Expected snapshot")
        return
    }
    #expect(snapshot.monitoring == .paused)
    #expect(snapshot.readiness == .notInstalled)
    #expect(snapshot.sampledAt != nil)
    #expect(snapshot.notifications.isEmpty)
    try await store.close()
}

@Test func staleRuleAndPriorDayNotificationACKFail() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try QuotaStore(path: folder.appendingPathComponent("test.sqlite").path)
    let runtime = AgentRuntime(store: store)
    try await store.registerApplication(AppIdentity(key: "app", name: "App"))
    _ = try await runtime.handle(.saveRule(appKey: "app", rule: QuotaRule(limitBytes: 1, version: 2)))
    let day = try LocalDay.key(for: Date(), in: .current)
    for identity in [try QuotaIdentity(appKey: "app", day: day, ruleVersion: 1),
                     try QuotaIdentity(appKey: "app", day: "2000-01-01", ruleVersion: 2)] {
        await #expect(throws: (any Error).self) {
            try await runtime.handle(.acknowledgeNotification(QuotaNotificationKey(identity: identity, kind: .blocked)))
        }
    }
    #expect(try await store.deliveredNotifications(day: day).isEmpty)
    try await store.close()
}

private extension AgentRuntime {
    func publishSampleForTesting() {
        sampledAt = Date()
        monitoring = .collecting
    }
}

@Test func agentExecutablePathIsAbsolute() throws {
    let executable = try AgentExecutablePath.current()
    #expect(executable.isFileURL)
    #expect(executable.path.hasPrefix("/"))
}
