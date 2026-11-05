import Foundation
import FlowQuotaCore
import Testing
@testable import FlowQuotaApp

@MainActor @Test func expensiveNetworkShowsAutomaticMeteringAndDeliversReminderWithoutManualMark() async throws {
    let event = try reminder()
    let client = FakeAgentClient(applications: [try application(used: 100)], monitoring: .collecting,
                                 sampledAt: Date(), notifications: [event], network: .expensive,
                                 interfaceUsage: try interfaceUsage(), interfaceSampledAt: Date())
    let scheduler = FakeReminderScheduler()
    let state = AppState(client: client, scheduler: scheduler)
    await state.refresh()
    #expect(state.networkTitle == "当前连接：高成本网络")
    #expect(state.networkDetail.contains("不表示已确认手机热点"))
    #expect(!state.hotspotMarked)
    #expect(!state.showsHotspotControl)
    #expect(client.marked == nil)
    #expect(state.usageAvailable)
    #expect(state.totalUsage == 200)
    #expect(state.canEdit)
    #expect(scheduler.scheduled == [event.id])
    #expect(client.acknowledgements == [event.key])
}

@MainActor @Test func manualHotspotKeepsCancellationAndSharesReminderPresentation() async throws {
    let event = try reminder()
    let client = FakeAgentClient(applications: [try application(used: 100)], monitoring: .collecting,
                                 sampledAt: Date(), notifications: [event], network: .hotspot,
                                 interfaceUsage: try interfaceUsage(), interfaceSampledAt: Date())
    let scheduler = FakeReminderScheduler()
    let state = AppState(client: client, scheduler: scheduler)
    await state.refresh()
    #expect(state.hotspotMarked)
    #expect(state.showsHotspotControl)
    #expect(state.networkTitle == "当前连接：手动标记为热点")
    #expect(state.totalUsage == 200)
    #expect(scheduler.scheduled == [event.id])
    #expect(client.acknowledgements == [event.key])
    state.setHotspotOverride(false)
    await finishOperation(state)
    #expect(client.marked == false)
}

@MainActor @Test func ordinaryAndUnknownKeepManualFallbackAndObservedDailyUsage() async throws {
    for network in [NetworkState.ordinary, .unknown] {
        let client = FakeAgentClient(applications: [try application(used: 42)], monitoring: .collecting,
                                     sampledAt: Date(), network: network,
                                     interfaceUsage: try interfaceUsage(uploaded: 84, downloaded: 0))
        let state = AppState(client: client)
        await state.refresh()
        #expect(!state.hotspotMarked)
        #expect(state.showsHotspotControl)
        #expect(state.canConfigureNetwork)
        #expect(state.networkUnavailableReason.isEmpty)
        // Leaving the metered path retains the independent interface daily total.
        #expect(state.totalUsage == 84)
        state.setHotspotOverride(true)
        await finishOperation(state)
        #expect(client.marked == true)
    }
}

@MainActor @Test func staleOrDisconnectedExpensiveSnapshotCannotClaimAutomaticMetering() async {
    let client = FakeAgentClient(date: Date().addingTimeInterval(-30), network: .expensive)
    let state = AppState(client: client)
    await state.refresh()
    #expect(state.networkTitle == "当前连接：未知")
    #expect(!state.hotspotMarked)
    #expect(state.showsHotspotControl)
    #expect(!state.canConfigureNetwork)
    #expect(!state.networkUnavailableReason.isEmpty)
    #expect(!state.usageAvailable)
    client.fetchFails = true
    await state.refresh()
    #expect(state.networkTitle == "当前连接：未知")
    #expect(state.showsHotspotControl)
    #expect(!state.canConfigureNetwork)
    #expect(state.networkUnavailableReason.contains("未连接"))
}
