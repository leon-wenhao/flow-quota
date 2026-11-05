import Testing
@testable import FlowQuotaPlatform

private struct FakeInterfaceCounter: InterfaceCounterReading {
    let snapshot: InterfaceCounterSnapshot

    func read(interfaceIndex: UInt32) throws -> InterfaceCounterSnapshot {
        guard interfaceIndex == snapshot.interfaceIndex else {
            throw InterfaceCounterError.interfaceUnavailable(interfaceIndex)
        }
        return snapshot
    }
}

private let interfaceScope = InterfaceTrafficScope(day: "2026-11-05", pathGeneration: 1)

private func counter(_ up: UInt64, _ down: UInt64 = 0, index: UInt32 = 4) -> InterfaceCounterSnapshot {
    InterfaceCounterSnapshot(interfaceIndex: index, uploadedBytes: up, downloadedBytes: down)
}

@Suite struct InterfaceTrafficAccumulatorTests {
    @Test func injectableFakePreserves64BitCountersAndMeasuredZero() throws {
        var accumulator = InterfaceTrafficAccumulator()
        let large = UInt64(UInt32.max) + 1_000
        let first: any InterfaceCounterReading = FakeInterfaceCounter(snapshot: counter(large, large))
        let baseline = try accumulator.consume(first.read(interfaceIndex: 4), scope: interfaceScope, uptime: 1)
        #expect(baseline.status == .baseline(.firstSample))
        #expect(baseline.rebaselined)
        let next = FakeInterfaceCounter(snapshot: counter(large + 10, large + 20))
        let delta = try accumulator.consume(next.read(interfaceIndex: 4), scope: interfaceScope, uptime: 2)
        #expect(delta.uploadedBytes == 10)
        #expect(delta.downloadedBytes == 20)
        #expect(delta.status == .measured)
        #expect(!delta.rebaselined)
        let zero = try accumulator.consume(next.read(interfaceIndex: 4), scope: interfaceScope, uptime: 3)
        #expect(zero.status == .measured)
        #expect(zero.uploadedBytes == 0 && zero.downloadedBytes == 0)
    }

    @Test(arguments: [true, false]) func eitherCounterResetDiscardsBothDirections(uploadReset: Bool) throws {
        var accumulator = InterfaceTrafficAccumulator()
        _ = try accumulator.consume(counter(100, 100), scope: interfaceScope, uptime: 1)
        let sample = counter(uploadReset ? 1 : 120, uploadReset ? 120 : 1)
        let reset = try accumulator.consume(sample, scope: interfaceScope, uptime: 2)
        #expect(reset.status == .baseline(.counterReset))
        #expect(reset.uploadedBytes == 0 && reset.downloadedBytes == 0)
        let resumed = counter(sample.uploadedBytes + 5, sample.downloadedBytes + 6)
        let delta = try accumulator.consume(resumed, scope: interfaceScope, uptime: 3)
        #expect(delta.uploadedBytes == 5 && delta.downloadedBytes == 6)
    }

    @Test func interfaceChangesNeverSubtractUnrelatedCounters() throws {
        var accumulator = InterfaceTrafficAccumulator()
        _ = try accumulator.consume(counter(100), scope: interfaceScope, uptime: 1)
        let result = try accumulator.consume(counter(10_000, index: 8), scope: interfaceScope, uptime: 2)
        #expect(result.status == .baseline(.interfaceChanged))
        #expect(result.uploadedBytes == 0)
        let resumed = try accumulator.consume(counter(10_003, index: 8), scope: interfaceScope, uptime: 3)
        #expect(resumed.uploadedBytes == 3)
    }

    @Test func missingInterfacesAndExplicitResetForgetBaseline() throws {
        var accumulator = InterfaceTrafficAccumulator()
        _ = try accumulator.consume(counter(100), scope: interfaceScope, uptime: 1)
        let missing = try accumulator.consume(nil, scope: interfaceScope, uptime: 2)
        #expect(missing.status == .unavailable)
        #expect(missing.rebaselined)
        let resumed = try accumulator.consume(counter(10_000), scope: interfaceScope, uptime: 3)
        #expect(resumed.status == .baseline(.firstSample))
        accumulator.reset()
        #expect(try accumulator.consume(counter(20_000), scope: interfaceScope, uptime: 4).uploadedBytes == 0)
    }

    @Test(arguments: [
        InterfaceTrafficScope(day: "2026-11-06", pathGeneration: 1),
        InterfaceTrafficScope(day: "2026-11-05", pathGeneration: 2)
    ]) func dayAndPathGenerationChangesRebaseline(scope: InterfaceTrafficScope) throws {
        var accumulator = InterfaceTrafficAccumulator()
        _ = try accumulator.consume(counter(100), scope: interfaceScope, uptime: 1)
        let result = try accumulator.consume(counter(900), scope: scope, uptime: 2)
        #expect(result.status == .baseline(.scopeChanged))
        #expect(result.uploadedBytes == 0)
    }

    @Test(arguments: [UInt64(100), 99, 8_000_000_101])
    func nonIncreasingOrLongUptimeGapsRebaseline(uptime: UInt64) throws {
        var accumulator = InterfaceTrafficAccumulator()
        _ = try accumulator.consume(counter(100), scope: interfaceScope, uptime: 100)
        let result = try accumulator.consume(counter(900), scope: interfaceScope, uptime: uptime)
        #expect(result.status == .baseline(.sampleGap))
        #expect(result.uploadedBytes == 0)
    }

    @Test func exactMaximumIntervalAndCustomIntervalAreRespected() throws {
        var accumulator = InterfaceTrafficAccumulator(maximumIntervalNanoseconds: 2)
        _ = try accumulator.consume(counter(100), scope: interfaceScope, uptime: 1)
        #expect(try accumulator.consume(counter(110), scope: interfaceScope, uptime: 3).uploadedBytes == 10)
        #expect(try accumulator.consume(counter(900), scope: interfaceScope, uptime: 6).rebaselined)
    }

    @Test(arguments: [
        counter(UInt64(Int64.max) + 1), counter(UInt64(Int64.max), 1), counter(UInt64.max, UInt64.max)
    ]) func overflowThrowsAndClearsBaseline(snapshot: InterfaceCounterSnapshot) throws {
        var accumulator = InterfaceTrafficAccumulator()
        _ = try accumulator.consume(counter(0), scope: interfaceScope, uptime: 1)
        #expect(throws: InterfaceCounterError.deltaOverflow) {
            try accumulator.consume(snapshot, scope: interfaceScope, uptime: 2)
        }
        let result = try accumulator.consume(counter(900), scope: interfaceScope, uptime: 3)
        #expect(result.status == .baseline(.firstSample))
    }

    @Test func failedFakeReadMustBreakContinuity() throws {
        var accumulator = InterfaceTrafficAccumulator()
        let fake = FakeInterfaceCounter(snapshot: counter(100))
        _ = try accumulator.consume(fake.read(interfaceIndex: 4), scope: interfaceScope, uptime: 1)
        #expect(throws: InterfaceCounterError.interfaceUnavailable(8)) { try fake.read(interfaceIndex: 8) }
        accumulator.reset() // Integrator's error path, not a fabricated zero sample.
        let result = try accumulator.consume(counter(900), scope: interfaceScope, uptime: 3)
        #expect(result.status == .baseline(.firstSample))
    }
}
