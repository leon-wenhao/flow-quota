import Foundation
import FlowQuotaCore
import Testing
@testable import FlowQuotaApp

@MainActor @Test func unreadyServiceKeepsUsageUnknownButAllowsNetworkMark() async throws {
    let client = FakeAgentClient(applications: [try application()])
    let state = AppState(client: client)
    await state.refresh()
    #expect(state.connected)
    #expect(state.totalUsage == nil)
    #expect(!state.canEdit)
    #expect(state.canConfigureNetwork)
    state.setHotspotOverride(true)
    await finishOperation(state)
    #expect(client.marked == true)
}

@MainActor @Test func failedFetchRecoversWithoutStaleErrorOrZeroUsage() async {
    let client = FakeAgentClient()
    let state = AppState(client: client)
    client.fetchFails = true
    await state.refresh()
    #expect(!state.connected)
    #expect(state.connectionError != nil)
    #expect(state.totalUsage == nil)
    client.fetchFails = false
    await state.refresh()
    #expect(state.connected)
    #expect(state.connectionError == nil)
}

@MainActor @Test func rejectedSaveDoesNotAcknowledgeAndCanRetry() async throws {
    let client = FakeAgentClient(readiness: .ready, applications: [try application()])
    let state = AppState(client: client)
    await state.refresh()
    let updated = try QuotaRule(limitBytes: 200, version: 2)
    var acknowledged = false
    client.saveFails = true
    state.save(appKey: "signed.test", rule: updated) { acknowledged = true }
    await finishOperation(state)
    #expect(!acknowledged)
    #expect(client.savedRules == 0)
    #expect(state.errorMessage != nil)
    client.saveFails = false
    state.save(appKey: "signed.test", rule: updated) { acknowledged = true }
    await finishOperation(state)
    #expect(acknowledged)
    #expect(client.savedRules == 1)
}

@MainActor @Test func staleRuleIsRejectedBeforeServiceWrite() async throws {
    let client = FakeAgentClient(readiness: .ready, applications: [try application()])
    let state = AppState(client: client)
    await state.refresh()
    state.save(appKey: "signed.test", rule: try QuotaRule(limitBytes: 200, version: 1)) {
        Issue.record("A stale rule cannot be acknowledged")
    }
    #expect(client.savedRules == 0)
    #expect(state.errorMessage != nil)
}

@MainActor @Test func expiredSnapshotsCannotEnableEditing() async throws {
    let client = FakeAgentClient(readiness: .ready, date: Date().addingTimeInterval(-30),
                                 applications: [try application()])
    let state = AppState(client: client)
    await state.refresh()
    #expect(!state.canEdit)
    #expect(!state.canConfigureNetwork)
    #expect(state.totalUsage == nil)
}

@MainActor @Test func stopFailureDoesNotQuitAndAcknowledgementAllowsRetry() async {
    let client = FakeAgentClient()
    let state = AppState(client: client)
    await state.refresh()
    var allowed: Bool?
    client.stopFails = true
    state.stopForTermination { allowed = $0 }
    await finishOperation(state)
    #expect(allowed == false)
    #expect(!state.quitRequested)
    client.stopFails = false
    state.stopForTermination { allowed = $0 }
    await finishOperation(state)
    #expect(allowed == true)
}
