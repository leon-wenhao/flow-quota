import Foundation
import Testing
@testable import FlowQuotaAgent

@Test @MainActor func terminationBeforeConfigurationWaitsForCleanupAndCoalescesSignals() async {
    let probe = TerminationProbe()
    let termination = AgentTermination(timeout: .seconds(5), exit: { probe.record($0) })
    termination.request()
    termination.request()
    #expect(termination.requested)
    #expect(probe.statuses.isEmpty)

    let entered = AsyncStream<Void>.makeStream()
    var release: CheckedContinuation<Void, Never>?
    var stops = 0
    termination.configure {
        stops += 1
        await withCheckedContinuation {
            release = $0
            entered.continuation.yield(())
        }
    }
    for await _ in entered.stream { break }
    #expect(stops == 1)
    #expect(probe.statuses.isEmpty) // Never exit before asynchronous sampler cleanup.
    release?.resume()
    for await status in probe.events { #expect(status == 0); break }
    termination.request()
    await Task.yield()
    #expect(stops == 1)
    #expect(probe.statuses == [0])
}

@Test @MainActor func terminationDeadlineBoundsUnconfiguredStartupAndExitsOnlyOnce() async {
    let probe = TerminationProbe()
    let termination = AgentTermination(timeout: .milliseconds(20), exit: { probe.record($0) })
    termination.request()
    for await status in probe.events { #expect(status == 1); break }
    #expect(probe.statuses == [1])

    // Startup can finish after the watchdog wins; late cleanup must not exit twice.
    let cleaned = AsyncStream<Void>.makeStream()
    termination.configure { cleaned.continuation.yield(()) }
    for await _ in cleaned.stream { break }
    await Task.yield()
    #expect(probe.statuses == [1])
}

@Test @MainActor func terminationCleanupFailureExitsWithFailure() async {
    struct StopFailure: Error {}
    let probe = TerminationProbe()
    let termination = AgentTermination(timeout: .seconds(5), exit: { probe.record($0) })
    termination.configure { throw StopFailure() }
    termination.request()
    for await status in probe.events { #expect(status == 1); break }
    #expect(probe.statuses == [1])
}

/// The exit callback also runs on the independent watchdog queue.
private final class TerminationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int32] = []
    let events: AsyncStream<Int32>
    private let continuation: AsyncStream<Int32>.Continuation

    init() {
        let stream = AsyncStream<Int32>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }

    var statuses: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ status: Int32) {
        lock.lock()
        recorded.append(status)
        lock.unlock()
        continuation.yield(status)
    }
}
