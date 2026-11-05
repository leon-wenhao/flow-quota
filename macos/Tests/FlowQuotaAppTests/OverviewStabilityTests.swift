import FlowQuotaCore
import Foundation
import Testing
@testable import FlowQuotaApp

private func listedApp(_ key: String, bytes: Int64) throws -> ApplicationSnapshot {
    ApplicationSnapshot(identity: AppIdentity(key: key, name: key), rule: nil,
        usage: DailyUsage(appKey: key, day: try LocalDay.key(for: Date(), in: .current),
                          uploadedBytes: bytes, downloadedBytes: 0))
}

@Test func usagePollingUpdatesValuesWithoutMovingExistingApplications() throws {
    let first = try [listedApp("a", bytes: 200), listedApp("b", bytes: 100)]
    let later = try [listedApp("b", bytes: 900), listedApp("a", bytes: 250)]
    var order = ApplicationListOrder()
    order.reconcile(first)
    order.reconcile(later)
    #expect(order.ordered(later).map(\.id) == ["a", "b"])
    #expect(order.ordered(later).map { $0.usage.uploadedBytes } == [250, 900])
    order.sortByUsage(later)
    #expect(order.ordered(later).map(\.id) == ["b", "a"])
}

@Test func membershipChangesAppendNewSourcesAndRemoveOnlyMissingSources() throws {
    var order = ApplicationListOrder()
    order.reconcile(try [listedApp("a", bytes: 200), listedApp("b", bytes: 100)])
    let later = try [listedApp("c", bytes: 900), listedApp("b", bytes: 150)]
    order.reconcile(later)
    #expect(order.ordered(later).map(\.id) == ["b", "c"])
    order.reconcile(later)
    #expect(order.keys == ["b", "c"])
}

@MainActor @Test func pausedCostlyNetworkDoesNotClaimActiveMetering() async throws {
    let client = FakeAgentClient(monitoring: .paused, network: .expensive,
                                 interfaceUsage: try interfaceUsage(), interfaceSampledAt: Date())
    let state = AppState(client: client, scheduler: FakeReminderScheduler())
    await state.refresh()
    #expect(state.networkName == "高成本网络")
    #expect(!state.networkTitle.contains("已自动计量"))
    #expect(state.interfaceSummary.contains("保留"))
    #expect(MonitoringPresentation(state: state).title == "应用采集已暂停")
    #expect(!MonitoringPresentation(state: state).collecting)
}

@MainActor @Test func compactInterfacePresentationRemainsIndependentOfApplicationFailure() async throws {
    let client = FakeAgentClient(monitoring: .failed, network: .expensive,
                                 interfaceUsage: try interfaceUsage(), interfaceSampledAt: Date())
    let state = AppState(client: client, scheduler: FakeReminderScheduler())
    await state.refresh()
    #expect(state.totalUsage == 200)
    #expect(state.interfaceSummary.contains("上传＋下载"))
    #expect(MonitoringPresentation(state: state).failed)
    client.fetchFails = true
    await state.refresh()
    #expect(state.interfaceSummary.contains("未知"))
    #expect(state.totalUsage == nil)
}

@MainActor @Test func manualRefreshDoesNotInsertAnOperationRowOrDiscardPreviousUsage() async throws {
    let client = FakeAgentClient(monitoring: .paused, interfaceUsage: try interfaceUsage())
    let state = AppState(client: client, scheduler: FakeReminderScheduler())
    await state.refresh()
    let count = client.fetchCount
    state.refreshOnce()
    #expect(state.operation == nil)
    #expect(state.totalUsage == 200)
    let deadline = ContinuousClock.now + .seconds(2)
    while client.fetchCount == count && ContinuousClock.now < deadline { await Task.yield() }
    #expect(client.fetchCount > count)
    #expect(state.operation == nil)
    #expect(state.totalUsage == 200)
}

@MainActor @Test func capacityAndEvaluationFailuresRemainVisibleInCompactOverview() async {
    let client = FakeAgentClient()
    let state = AppState(client: client, scheduler: FakeReminderScheduler())
    for message in ["应用预警覆盖不完整：活跃应用超过 128 项。",
                    "接口预警未完成：今日预警记录已达 256 条上限。"] {
        client.state = AgentSnapshot(generatedAt: Date(), network: .expensive, readiness: .notInstalled,
            applications: [], message: "Fixture", monitoring: .collecting, trafficAlertMessage: message)
        await state.refresh()
        #expect(state.trafficAlertWarning == message)
    }
    client.fetchFails = true
    await state.refresh()
    #expect(state.trafficAlertWarning == nil)
}
