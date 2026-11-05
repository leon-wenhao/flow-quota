import Foundation
import FlowQuotaCore
import Testing
@testable import FlowQuotaApp

private func samplingSnapshot(enabled: Bool?, monitoring: MonitoringStatus,
                              date: Date = Date()) -> AgentSnapshot {
    AgentSnapshot(generatedAt: date, network: .ordinary, readiness: .notInstalled,
                  applications: [], message: "Test service", monitoring: monitoring,
                  samplingEnabled: enabled)
}

@MainActor @Test func samplingSwitchUsesConfirmedStateForPauseAndResume() async throws {
    let client = FakeAgentClient()
    client.state = samplingSnapshot(enabled: true, monitoring: .collecting)
    let state = AppState(client: client, scheduler: FakeReminderScheduler())
    await state.refresh()
    #expect(state.samplingEnabled == true)
    client.state = samplingSnapshot(enabled: false, monitoring: .paused)
    state.setSamplingEnabled(false)
    #expect(state.samplingEnabled == true)
    #expect(!state.canChangeSampling)
    // A repeated gesture while waiting must not submit another stop or start.
    state.setSamplingEnabled(false)
    state.setSamplingEnabled(true)
    await finishOperation(state)
    #expect(client.stoppedCount == 1)
    #expect(client.enabledCount == 0)
    #expect(state.samplingEnabled == false)
    #expect(!state.quitRequested)
    client.state = samplingSnapshot(enabled: true, monitoring: .unavailable)
    state.setSamplingEnabled(true)
    await finishOperation(state)
    #expect(client.enabledCount == 1)
    #expect(state.samplingEnabled == true)
    // Duplicate writes of the confirmed value are no-ops.
    state.setSamplingEnabled(true)
    #expect(!state.busy)
}

@MainActor @Test func failedApplicationSamplerKeepsInterfaceCollectionSwitchOnAndPauseFailureVisible() async {
    let client = FakeAgentClient()
    client.state = samplingSnapshot(enabled: true, monitoring: .failed)
    client.stopFails = true
    let state = AppState(client: client, scheduler: FakeReminderScheduler())
    await state.refresh()
    #expect(state.samplingEnabled == true)
    #expect(state.canChangeSampling)
    state.setSamplingEnabled(false)
    await finishOperation(state)
    #expect(state.samplingEnabled == true)
    #expect(state.errorMessage?.contains("test stop rejected") == true)
}

@MainActor @Test func unknownDisconnectedAndExpiredCollectionCannotMasqueradeAsOff() async {
    let client = FakeAgentClient()
    let state = AppState(client: client, scheduler: FakeReminderScheduler())
    for (enabled, date) in [(nil, Date()), (true, Date().addingTimeInterval(-30))] as [(Bool?, Date)] {
        client.state = samplingSnapshot(enabled: enabled, monitoring: .failed, date: date)
        await state.refresh()
        #expect(state.samplingEnabled == nil)
        #expect(!state.canChangeSampling)
        state.setSamplingEnabled(true)
        #expect(!state.busy)
    }
    client.fetchFails = true
    await state.refresh()
    #expect(state.samplingEnabled == nil)
    #expect(client.enabledCount == 0)
    #expect(client.stoppedCount == 0)
}

@Test func samplingSwitchProtocolSupportsMissingFieldAndPreservesExplicitState() throws {
    let original = samplingSnapshot(enabled: true, monitoring: .failed)
    let data = try JSONEncoder().encode(original)
    #expect(try JSONDecoder().decode(AgentSnapshot.self, from: data).samplingEnabled == true)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "samplingEnabled")
    let oldData = try JSONSerialization.data(withJSONObject: object)
    #expect(try JSONDecoder().decode(AgentSnapshot.self, from: oldData).samplingEnabled == nil)
}
