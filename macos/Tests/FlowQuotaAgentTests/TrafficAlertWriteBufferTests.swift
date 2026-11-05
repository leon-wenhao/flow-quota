import Foundation
import FlowQuotaCore
import Testing
@testable import FlowQuotaAgent

private func candidate(_ kind: TrafficAlertKind = .applicationBurst, source: String = "exec:/one",
                       bytes: Int64 = 250_000_000, version: Int64 = 1) -> TrafficAlertEvent {
    TrafficAlertEvent(day: "2026-11-05", kind: kind, sourceKey: kind == .applicationBurst ? source : "",
        sourceName: "Source", observedBytes: bytes, thresholdBytes: 200_000_000,
        windowSeconds: kind == .dailyInterface ? 0 : 180, observedSeconds: kind == .dailyInterface ? 0 : 2,
        policyVersion: version, occurredAt: Date(timeIntervalSince1970: 1_793_836_800))
}

@Test func retryBufferPreservesOriginalCrossingAndBoundsApplicationSources() throws {
    var buffer = TrafficAlertWriteBuffer()
    let first = candidate(.interfaceBurst)
    try buffer.stage(first)
    try buffer.stage(candidate(.interfaceBurst, bytes: 900_000_000))
    #expect(buffer.candidates(kind: .interfaceBurst) == [first])
    try buffer.stage(candidate(.dailyInterface))
    for index in 0..<128 { try buffer.stage(candidate(source: "exec:/source-\(index)")) }
    #expect(buffer.count == 130)
    do {
        try buffer.stage(candidate(source: "exec:/overflow"))
        Issue.record("Expected bounded application retry sources")
    } catch {
        guard case TrafficAlertError.pendingEventLimit = error else { throw error }
    }
    let app = try #require(buffer.candidates(kind: .applicationBurst).first)
    buffer.remove(app)
    try buffer.stage(candidate(source: "exec:/overflow"))
    #expect(buffer.count == 130)
}

@Test func retriesPruneDisabledChangedAndOldDayEventsWithoutDeletingReplacements() throws {
    var buffer = TrafficAlertWriteBuffer()
    let old = candidate(.interfaceBurst)
    try buffer.stage(old)
    let changed = try TrafficAlertPolicy(dailyInterfaceBytes: nil, interfaceBurstBytes: 200_000_000,
                                        applicationBurstBytes: nil, version: 2)
    buffer.retain(day: old.day, policy: changed)
    #expect(buffer.count == 0)
    let replacement = candidate(.interfaceBurst, version: 2)
    try buffer.stage(replacement)
    buffer.remove(old)
    #expect(buffer.candidates(kind: .interfaceBurst) == [replacement])
    buffer.retain(day: "2026-11-06", policy: changed)
    #expect(buffer.count == 0)
    try buffer.stage(replacement)
    let disabled = try TrafficAlertPolicy(dailyInterfaceBytes: nil, interfaceBurstBytes: nil,
                                         applicationBurstBytes: nil, version: 2)
    buffer.retain(day: old.day, policy: disabled)
    #expect(buffer.count == 0)
}
