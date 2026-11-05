import Foundation
import FlowQuotaCore
import Observation
import Testing
@testable import FlowQuotaApp

@MainActor private func alertSnapshot(events: [TrafficAlertEvent], monitoring: MonitoringStatus = .failed,
                                     date: Date = Date(), policy: TrafficAlertPolicy = .initial) -> AgentSnapshot {
    AgentSnapshot(generatedAt: date, network: .expensive, readiness: .notInstalled,
        applications: [], message: "Injected snapshot", monitoring: monitoring,
        trafficAlertPolicy: policy, trafficAlertEvents: events, pendingTrafficAlerts: events)
}

@MainActor @Test func independentInterfaceAlertDeliversWhenApplicationSamplingFails() async throws {
    let client = FakeAgentClient()
    let event = try trafficEvent()
    client.state = alertSnapshot(events: [event])
    let scheduler = FakeReminderScheduler()
    let state = AppState(client: client, scheduler: scheduler)
    await state.refresh()
    #expect(scheduler.scheduledAlerts.map(\.id) == [event.id])
    #expect(client.alertAcknowledgements == [event.id])
    #expect(!state.usageAvailable)
}

@MainActor @Test func expiredPausedAndChangedPolicyCannotDeliverTrafficAlerts() async throws {
    let event = try trafficEvent()
    let changed = try TrafficAlertPolicy(dailyInterfaceBytes: nil, interfaceBurstBytes: nil,
        applicationBurstBytes: nil, version: 2)
    for snapshot in [alertSnapshot(events: [event], monitoring: .paused),
                     alertSnapshot(events: [event], date: Date().addingTimeInterval(-30)),
                     alertSnapshot(events: [event], policy: changed)] {
        let client = FakeAgentClient()
        client.state = snapshot
        let scheduler = FakeReminderScheduler()
        let state = AppState(client: client, scheduler: scheduler)
        await state.refresh()
        #expect(scheduler.scheduledAlerts.isEmpty)
        #expect(client.alertAcknowledgements.isEmpty)
    }
}

@MainActor @Test func changingAlertPolicyDuringAuthorizationCancelsOldProposal() async throws {
    let client = FakeAgentClient()
    client.state = alertSnapshot(events: [try trafficEvent()])
    let scheduler = FakeReminderScheduler()
    scheduler.holdAuthorization = true
    let state = AppState(client: client, scheduler: scheduler)
    let refresh = Task { await state.refresh() }
    let deadline = ContinuousClock.now + .seconds(2)
    while scheduler.authorizationGate == nil && ContinuousClock.now < deadline { await Task.yield() }
    #expect(scheduler.authorizationGate != nil)
    let next = try TrafficAlertPolicy(dailyInterfaceBytes: nil, interfaceBurstBytes: nil,
        applicationBurstBytes: nil, version: 2)
    client.state = alertSnapshot(events: client.state.pendingTrafficAlerts, policy: next)
    await state.refresh()
    scheduler.authorizationGate?.resume()
    await refresh.value
    #expect(scheduler.scheduledAlerts.isEmpty)
    #expect(client.alertAcknowledgements.isEmpty)
}

@MainActor @Test func alertPolicySaveFailureKeepsDraftUnacknowledgedAndAllowsRetry() async throws {
    let client = FakeAgentClient()
    client.state = alertSnapshot(events: [])
    let state = AppState(client: client, scheduler: FakeReminderScheduler())
    await state.refresh()
    let policy = try #require(TrafficAlertDraft(.initial).policy)
    var closed = false
    client.saveFails = true
    state.saveTrafficAlertPolicy(policy) { closed = true }
    await finishOperation(state)
    #expect(!closed)
    #expect(state.errorMessage != nil)
    #expect(client.savedAlertPolicy == nil)
    client.saveFails = false
    state.saveTrafficAlertPolicy(policy) { closed = true }
    await finishOperation(state)
    #expect(closed)
    #expect(client.savedAlertPolicy == policy)
}

@MainActor @Test func historyUsesBoundedPagesAndRejectsDisconnectedRead() async throws {
    let client = FakeAgentClient()
    let events = try (0..<256).map { _ in try trafficEvent() }
    client.state = alertSnapshot(events: events, monitoring: .paused)
    let state = AppState(client: client, scheduler: FakeReminderScheduler())
    await state.refresh()
    #expect(try await state.loadTodayTrafficAlerts().count == 256)
    #expect(client.historyOffsets == Array(stride(from: 0, to: 256, by: 32)))
    client.fetchFails = true
    await state.refresh()
    await #expect(throws: TrafficAlertError.self) { try await state.loadTodayTrafficAlerts() }
}

private final class ObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    func set() { lock.withLock { stored = true } }
    var value: Bool { lock.withLock { stored } }
}

@MainActor @Test func notificationFailureIsObservableThroughTheSharedDeliveryWrapper() async throws {
    let client = FakeAgentClient()
    let scheduler = FakeReminderScheduler()
    scheduler.status = .denied
    let state = AppState(client: client, scheduler: scheduler)
    let flag = ObservationFlag()
    withObservationTracking { _ = state.trafficAlertDelivery.errorMessage } onChange: { flag.set() }
    await state.trafficAlertDelivery.deliver([try trafficEvent()])
    #expect(flag.value)
    #expect(state.trafficAlertDelivery.errorMessage != nil)
}


@MainActor @Test func alertSaveFeedbackCoversPendingACKSuccessFailureAndRetry() async throws {
    let client = FakeAgentClient()
    client.state = alertSnapshot(events: [])
    client.holdAlertPolicySave = true
    let state = AppState(client: client, scheduler: FakeReminderScheduler())
    await state.refresh()
    let policy = try #require(TrafficAlertDraft(.initial).policy)
    var acknowledged = false
    state.saveTrafficAlertPolicy(policy) { acknowledged = true }
    while client.alertPolicySaveGate == nil { await Task.yield() }
    let pending = ServiceFeedbackPresentation(state: state)
    #expect(pending.working)
    #expect(pending.detail.contains("正在保存流量预警配置"))
    #expect(!pending.detail.contains("已持久化"))
    #expect(!acknowledged)
    client.saveFails = true
    client.alertPolicySaveGate?.resume()
    await finishOperation(state)
    let failed = ServiceFeedbackPresentation(state: state)
    #expect(failed.hasError)
    #expect(!failed.working)
    #expect(failed.detail.contains("test save rejected"))
    #expect(!acknowledged)
    client.holdAlertPolicySave = false
    client.saveFails = false
    state.saveTrafficAlertPolicy(policy) { acknowledged = true }
    await finishOperation(state)
    let saved = ServiceFeedbackPresentation(state: state)
    #expect(!saved.hasError)
    #expect(!saved.working)
    #expect(saved.detail.contains("已持久化"))
    #expect(acknowledged)
}
