import Foundation
import FlowQuotaCore
import Testing
@testable import FlowQuotaApp

@MainActor @Test func backgroundLoopDeliversWithoutCreatingPanelAndStopCancelsPolling() async throws {
    let event = try reminder()
    let client = FakeAgentClient(monitoring: .collecting, sampledAt: Date(), notifications: [event])
    let scheduler = FakeReminderScheduler()
    let state = AppState(client: client, scheduler: scheduler)
    let monitor = AppMonitor(state: state, interval: .milliseconds(10))
    monitor.start()
    monitor.start()
    defer { monitor.stop() }
    let deadline = ContinuousClock.now + .seconds(2)
    while client.fetchCount < 2 && ContinuousClock.now < deadline { await Task.yield() }
    #expect(client.fetchCount >= 2)
    #expect(scheduler.scheduled == [event.id])
    #expect(client.acknowledgements == [event.key])
    monitor.stop()
    // Let cancellation unwind before comparing counts. No SwiftUI view is instantiated.
    await Task.yield()
    let count = client.fetchCount
    try await Task.sleep(for: .milliseconds(35))
    #expect(client.fetchCount == count)
}

@MainActor @Test func expiredSnapshotCannotDeliverOldProposals() async throws {
    let client = FakeAgentClient(date: Date().addingTimeInterval(-30), monitoring: .collecting,
                                 sampledAt: Date(), notifications: [try reminder()])
    let scheduler = FakeReminderScheduler()
    let state = AppState(client: client, scheduler: scheduler)
    await state.refresh()
    #expect(scheduler.scheduled.isEmpty)
    #expect(client.acknowledgements.isEmpty)
}

@MainActor @Test func pausedFailedAndUnavailableSnapshotsDoNotDeliver() async throws {
    for monitoring in [MonitoringStatus.paused, .failed, .unavailable] {
        let client = FakeAgentClient(monitoring: monitoring, sampledAt: Date(), notifications: [try reminder()])
        let scheduler = FakeReminderScheduler()
        let state = AppState(client: client, scheduler: scheduler)
        await state.refresh()
        #expect(scheduler.scheduled.isEmpty)
        #expect(client.acknowledgements.isEmpty)
    }
}

@MainActor @Test func pauseDuringPermissionReadPreventsSchedulingFromEarlierSnapshot() async throws {
    let event = try reminder()
    let client = FakeAgentClient(monitoring: .collecting, sampledAt: Date(), notifications: [event])
    let scheduler = FakeReminderScheduler()
    scheduler.holdAuthorization = true
    let state = AppState(client: client, scheduler: scheduler)
    let refresh = Task { await state.refresh() }
    let deadline = ContinuousClock.now + .seconds(2)
    while scheduler.authorizationGate == nil && ContinuousClock.now < deadline { await Task.yield() }
    #expect(scheduler.authorizationGate != nil)
    client.state = AgentSnapshot(generatedAt: Date(), network: .hotspot, readiness: .notInstalled,
                                 applications: [], message: "Paused", monitoring: .paused,
                                 sampledAt: Date(), notifications: [event])
    await state.refresh()
    scheduler.authorizationGate?.resume()
    await refresh.value
    #expect(scheduler.scheduled.isEmpty)
    #expect(client.acknowledgements.isEmpty)
}
