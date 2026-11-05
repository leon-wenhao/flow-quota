import Foundation
import FlowQuotaCore
import FlowQuotaStore
import Testing
@testable import FlowQuotaAgent

@Test func samplingSwitchSnapshotSeparatesInterfaceCollectionFromApplicationFailure() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try QuotaStore(path: folder.appendingPathComponent("test.sqlite").path)
    let runtime = AgentRuntime(store: store)
    #expect(try await runtime.snapshot().samplingEnabled == false)
    // A task handle simulates interface-only service state; it reads no counters,
    // starts no nettop process and generates no network traffic.
    await runtime.simulateInterfaceOnlyCollection()
    let running = try await runtime.snapshot()
    #expect(running.monitoring == .failed)
    #expect(running.samplingEnabled == true)
    _ = try await runtime.handle(.stopProtection)
    let stopped = try await runtime.snapshot()
    #expect(stopped.monitoring == .paused)
    #expect(stopped.samplingEnabled == false)
    try await store.close()
}

private extension AgentRuntime {
    func simulateInterfaceOnlyCollection() {
        monitoring = .failed
        interfaceTask = Task {}
    }
}
