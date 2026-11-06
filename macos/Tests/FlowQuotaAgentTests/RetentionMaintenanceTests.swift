import Foundation
import Testing
import FlowQuotaCore
import FlowQuotaStore
@testable import FlowQuotaAgent

@Test func retentionRunsWhilePausedWithoutUIOrSampling() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try QuotaStore(path: folder.appendingPathComponent("quota.sqlite").path)
    let yesterday = try LocalDay.key(for: Date().addingTimeInterval(-86_400), in: .current)
    try await store.recordSample(day: yesterday, increments: [], interfaceIncrement:
        InterfaceUsage(day: yesterday, uploadedBytes: 10, downloadedBytes: 20))
    let runtime = AgentRuntime(store: store)
    _ = try await runtime.handle(.stopProtection)
    try await runtime.startRetentionMaintenance()
    #expect(try await store.interfaceUsage(day: yesterday) == nil)
    #expect(await runtime.retentionTask != nil)
    #expect(await runtime.samplingTask == nil)
    #expect(await runtime.interfaceTask == nil)
    #expect(await runtime.monitoring == .paused)
    await runtime.stopRetentionMaintenance()
    #expect(await runtime.retentionTask == nil)
    try await store.close()
}
