import Foundation

public struct InterfaceTrafficScope: Equatable, Sendable {
    public let day: String
    public let pathGeneration: UInt64

    public init(day: String, pathGeneration: UInt64) {
        self.day = day
        self.pathGeneration = pathGeneration
    }
}

public enum InterfaceTrafficBaselineReason: Equatable, Sendable {
    case firstSample, scopeChanged, interfaceChanged, sampleGap, counterReset
}

public enum InterfaceTrafficDeltaStatus: Equatable, Sendable {
    case measured
    case unavailable
    case baseline(InterfaceTrafficBaselineReason)
}

public struct InterfaceTrafficDelta: Equatable, Sendable {
    public let uploadedBytes: Int64
    public let downloadedBytes: Int64
    public let status: InterfaceTrafficDeltaStatus

    public var rebaselined: Bool { status != .measured }
}

/// Ephemeral, caller-owned state. Serialize calls on the sampling task/actor.
/// Uptime and maximum interval use continuous monotonic nanoseconds from SamplingClock.
/// Scope changes, missing samples and discontinuities never backfill unknown use.
/// The caller gates metered networks and resets on read failure, pause or restart.
public struct InterfaceTrafficAccumulator: Sendable {
    private struct Baseline: Sendable {
        let snapshot: InterfaceCounterSnapshot
        let scope: InterfaceTrafficScope
        let uptime: UInt64
    }

    private var previous: Baseline?
    private let maximumIntervalNanoseconds: UInt64

    public init(maximumIntervalNanoseconds: UInt64 = 8_000_000_000) {
        self.maximumIntervalNanoseconds = maximumIntervalNanoseconds
    }

    public mutating func reset() { previous = nil }

    /// Nil clears the baseline and reports unavailable, distinct from measured zero.
    /// Deltas and their sum must fit nonnegative Int64 bytes; overflow clears the
    /// baseline and throws so a caller cannot accidentally bridge a failed interval.
    public mutating func consume(_ snapshot: InterfaceCounterSnapshot?, scope: InterfaceTrafficScope,
                                 uptime: UInt64) throws -> InterfaceTrafficDelta {
        guard let snapshot else {
            reset()
            return delta(.unavailable)
        }
        guard snapshot.interfaceIndex > 0, snapshot.interfaceIndex <= UInt16.max else {
            reset()
            throw InterfaceCounterError.invalidInterfaceIndex(snapshot.interfaceIndex)
        }
        let old = previous
        previous = Baseline(snapshot: snapshot, scope: scope, uptime: uptime)
        guard let old else { return delta(.baseline(.firstSample)) }
        guard old.scope == scope else { return delta(.baseline(.scopeChanged)) }
        guard old.snapshot.interfaceIndex == snapshot.interfaceIndex else {
            return delta(.baseline(.interfaceChanged))
        }
        guard uptime > old.uptime, uptime - old.uptime <= maximumIntervalNanoseconds else {
            return delta(.baseline(.sampleGap))
        }
        guard snapshot.uploadedBytes >= old.snapshot.uploadedBytes,
              snapshot.downloadedBytes >= old.snapshot.downloadedBytes else {
            return delta(.baseline(.counterReset))
        }
        guard let up = Int64(exactly: snapshot.uploadedBytes - old.snapshot.uploadedBytes),
              let down = Int64(exactly: snapshot.downloadedBytes - old.snapshot.downloadedBytes),
              !up.addingReportingOverflow(down).overflow else {
            reset()
            throw InterfaceCounterError.deltaOverflow
        }
        return InterfaceTrafficDelta(uploadedBytes: up, downloadedBytes: down, status: .measured)
    }

    private func delta(_ status: InterfaceTrafficDeltaStatus) -> InterfaceTrafficDelta {
        InterfaceTrafficDelta(uploadedBytes: 0, downloadedBytes: 0, status: status)
    }
}
