import Darwin
import Foundation
import FlowQuotaCore
import Testing
@testable import FlowQuotaPlatform
@testable import FlowQuotaStore
@testable import FlowQuotaAgent

final class RegressionCounter: InterfaceCounterReading, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: UInt64 = 0
    private var nanos: UInt64 = 1_000_000_000
    func setTime(_ value: UInt64) { lock.withLock { nanos = value } }
    func time() -> UInt64 { lock.withLock { nanos } }
    func set(_ value: UInt64) { lock.withLock { bytes = value } }
    func read(interfaceIndex: UInt32) throws -> InterfaceCounterSnapshot {
        lock.withLock { InterfaceCounterSnapshot(interfaceIndex: interfaceIndex, uploadedBytes: 0, downloadedBytes: bytes) }
    }
}

func withRegressionRuntime(_ body: (AgentRuntime, QuotaStore, RegressionCounter, NetworkObservation, URL) async throws -> Void) async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AlertRegression-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = NetworkObservation(state: .expensive, message: "simulated", generation: 7, interfaceIndexes: [4])
    let url = folder.appendingPathComponent("quota.sqlite")
    let store = try QuotaStore(path: url.path)
    let counter = RegressionCounter()
    let runtime = AgentRuntime(store: store, interfaceReader: counter, networkObservation: { path },
                               samplingTime: { counter.time() })
    try await body(runtime, store, counter, path, url)
    try await store.close()
}
