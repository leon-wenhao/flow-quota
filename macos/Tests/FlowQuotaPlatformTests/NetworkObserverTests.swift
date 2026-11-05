import Foundation
import FlowQuotaCore
import Testing
@testable import FlowQuotaPlatform

@Test func expensivePathsAutomaticallyCountWithoutManualConfirmation() throws {
    var state = NetworkTrackingState()
    #expect(state.snapshot.state == .unknown)
    #expect(!state.snapshot.state.countsTraffic)
    state.update(isAvailable: true, isExpensive: true)
    #expect(state.snapshot.state == .expensive)
    #expect(state.snapshot.state.countsTraffic)
    #expect(state.snapshot.message.contains("采集期间自动计量"))
    // The wire contract must distinguish system cost from a manual hotspot mark.
    let encoded = try JSONEncoder().encode(state.snapshot.state)
    #expect(try JSONDecoder().decode(NetworkState.self, from: encoded) == .expensive)
}

@Test func ordinaryAndDisconnectedPathsDoNotAutomaticallyCount() throws {
    var state = NetworkTrackingState()
    #expect(throws: (any Error).self) { try state.markCurrentPath(true) }
    state.update(isAvailable: true, isExpensive: false)
    #expect(state.snapshot.state == .ordinary)
    #expect(!state.snapshot.state.countsTraffic)
    state.update(isAvailable: false, isExpensive: true)
    #expect(state.snapshot.state == .unknown)
    #expect(!state.snapshot.state.countsTraffic)
    #expect(throws: (any Error).self) { try state.markCurrentPath(true) }
}

@Test func removingManualMarkRestoresTheActualAutomaticDecision() throws {
    for expensive in [false, true] {
        var state = NetworkTrackingState()
        state.update(isAvailable: true, isExpensive: expensive)
        let automatic = state.snapshot
        try state.markCurrentPath(true)
        #expect(state.snapshot.state == .hotspot)
        #expect(state.snapshot.generation > automatic.generation)
        let markedGeneration = state.snapshot.generation
        try state.markCurrentPath(true)
        #expect(state.snapshot.generation == markedGeneration)
        try state.markCurrentPath(false)
        #expect(state.snapshot.state == (expensive ? .expensive : .ordinary))
        #expect(state.snapshot.generation > markedGeneration)
    }
}

@Test func everyPathUpdateExpiresManualMarkAndAdvancesTheSamplingScope() throws {
    var state = NetworkTrackingState()
    state.update(isAvailable: true, isExpensive: false)
    try state.markCurrentPath(true)
    var previous = state.snapshot.generation
    // Even a connection update on the same interface invalidates a manual mark.
    for available in [true, false, true] {
        state.update(isAvailable: available, isExpensive: true)
        #expect(state.snapshot.state == (available ? .expensive : .unknown))
        #expect(state.snapshot.generation > previous)
        previous = state.snapshot.generation
    }
}

@Test func automaticMeteringNeverBackfillsTrafficAcrossNetworkChanges() throws {
    var network = NetworkTrackingState()
    var accumulator = TrafficAccumulator()
    let app = AppIdentity(key: "app:/Example.app", name: "Example")
    func sample(_ bytes: Int64, sequence: UInt64, path: NetworkObservation) throws -> Int64 {
        let result = try accumulator.consume([
            ResolvedProcessCounter(processKey: "123:birth", identity: app,
                                   uploadedBytes: bytes, downloadedBytes: 0)
        ], scope: "day:\(path.generation):\(path.state.rawValue)", sequence: sequence,
           uptime: sequence * 2_000_000_000, countTraffic: path.state.countsTraffic)
        return result.increments.first?.uploadedBytes ?? 0
    }
    network.update(isAvailable: true, isExpensive: false)
    #expect(try sample(100, sequence: 1, path: network.snapshot) == 0)
    #expect(try sample(200, sequence: 2, path: network.snapshot) == 0)
    network.update(isAvailable: true, isExpensive: true)
    #expect(try sample(900, sequence: 3, path: network.snapshot) == 0) // First metered baseline.
    #expect(try sample(920, sequence: 4, path: network.snapshot) == 20)
    network.update(isAvailable: true, isExpensive: false)
    #expect(try sample(999, sequence: 5, path: network.snapshot) == 0)
    try network.markCurrentPath(true)
    #expect(try sample(1100, sequence: 6, path: network.snapshot) == 0) // Manual baseline.
    #expect(try sample(1105, sequence: 7, path: network.snapshot) == 5)
}
