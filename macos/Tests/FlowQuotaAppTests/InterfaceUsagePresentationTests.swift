import Foundation
import FlowQuotaCore
import Testing
@testable import FlowQuotaApp

@MainActor @Test func interfaceTotalIsIndependentOfOverlappingApplicationUsage() async throws {
    let client = FakeAgentClient(applications: [try application(used: 1_000)], monitoring: .collecting,
                                 sampledAt: Date(), network: .expensive,
                                 interfaceUsage: try interfaceUsage(), interfaceSampledAt: Date(),
                                 interfaceMessage: "物理接口正在采样。")
    let state = AppState(client: client)
    await state.refresh()
    #expect(state.totalUsage == 200)
    #expect(state.interfaceUsageAvailable)
    #expect(!state.interfaceUsageIsPreserved)
    #expect(state.knownUsage(try application(used: 1_000)) == 1_000)
    #expect(state.interfaceServiceMessage == "物理接口正在采样。")
    #expect(state.menuBarUsageText == UsageFormatter.bytes(200))
}

@MainActor @Test func nonzeroApplicationUsageCannotFillMissingInterfaceTotal() async throws {
    let client = FakeAgentClient(applications: [try application(used: 1_000)], monitoring: .collecting,
                                 sampledAt: Date(), network: .expensive)
    let state = AppState(client: client)
    await state.refresh()
    #expect(state.usageAvailable)
    #expect(state.knownUsage(try application(used: 1_000)) == 1_000)
    #expect(state.totalUsage == nil)
    #expect(!state.interfaceUsageAvailable)
    #expect(state.menuBarUsageText == "未知")
    #expect(state.interfaceUsageReason.contains("不会用于补齐"))
    #expect(state.interfaceServiceMessage == "接口总量尚未就绪。")
}

@MainActor @Test func interfaceTotalDoesNotRequireApplicationSampleOrApplicationRows() async throws {
    for monitoring in [MonitoringStatus.failed, .unavailable] {
        let client = FakeAgentClient(monitoring: monitoring, network: .expensive,
                                     interfaceUsage: try interfaceUsage(), interfaceSampledAt: Date(),
                                     interfaceMessage: "物理接口正在采样；应用采样异常。")
        let state = AppState(client: client)
        await state.refresh()
        #expect(state.applications.isEmpty)
        #expect(!state.usageAvailable)
        #expect(state.totalUsage == 200)
        #expect(state.interfaceUsageAvailable)
        #expect(!state.interfaceUsageIsPreserved)
        #expect(!state.interfaceUsageReason.contains("未就绪"))
        #expect(state.interfaceMenuHelp.contains(client.state.interfaceMessage))
    }
}

@MainActor @Test func interfaceTotalWithDifferentDayRemainsUnknownDespiteApplicationUsage() async throws {
    let client = FakeAgentClient(applications: [try application(used: 1_000)], monitoring: .collecting,
                                 sampledAt: Date(), interfaceUsage: try interfaceUsage(day: "2000-01-01"),
                                 interfaceSampledAt: Date())
    let state = AppState(client: client)
    await state.refresh()
    #expect(state.knownUsage(try application(used: 1_000)) == 1_000)
    #expect(state.totalUsage == nil)
    #expect(!state.interfaceUsageAvailable)
    #expect(state.interfaceUsageReason.contains("日期与今天不符"))
}

@MainActor @Test func invalidInterfaceCountersNeverBecomeZeroOrApplicationSum() async throws {
    for usage in [try interfaceUsage(uploaded: -1), try interfaceUsage(downloaded: -1),
                  try interfaceUsage(uploaded: Int64.max, downloaded: 1)] {
        let client = FakeAgentClient(applications: [try application(used: 1_000)], monitoring: .collecting,
                                     sampledAt: Date(), interfaceUsage: usage, interfaceSampledAt: Date())
        let state = AppState(client: client)
        await state.refresh()
        #expect(state.totalUsage == nil)
        #expect(!state.interfaceUsageAvailable)
        #expect(state.interfaceUsageReason.contains("字节计数"))
        #expect(state.menuBarUsageText == "未知")
    }
}

@MainActor @Test func expiredOrFutureSnapshotCannotExposeInterfaceTotal() async throws {
    for age in [-30.0, 60.0] {
        let client = FakeAgentClient(date: Date().addingTimeInterval(age), monitoring: .collecting,
                                     sampledAt: Date(), interfaceUsage: try interfaceUsage(),
                                     interfaceSampledAt: Date())
        let state = AppState(client: client)
        await state.refresh()
        #expect(!state.snapshotIsCurrent)
        #expect(state.totalUsage == nil)
        #expect(!state.interfaceUsageAvailable)
        #expect(state.interfaceUsageReason.contains("快照已过期"))
    }
}

@MainActor @Test func disconnectedSnapshotCannotExposePreservedInterfaceTotal() async throws {
    let client = FakeAgentClient(monitoring: .collecting, interfaceUsage: try interfaceUsage(),
                                 interfaceSampledAt: Date())
    let state = AppState(client: client)
    await state.refresh()
    #expect(state.totalUsage == 200)
    client.fetchFails = true
    await state.refresh()
    #expect(state.totalUsage == nil)
    #expect(!state.interfaceUsageAvailable)
    #expect(state.interfaceUsageReason.contains("未连接"))
}

@MainActor @Test func pausedInterfaceRetainsDailyTotalWithVisiblePauseAndServiceMessage() async throws {
    let client = FakeAgentClient(monitoring: .paused, network: .expensive,
                                 interfaceUsage: try interfaceUsage(), interfaceSampledAt: Date(),
                                 interfaceMessage: "用户已暂停；恢复时重建接口基线。")
    let state = AppState(client: client)
    await state.refresh()
    #expect(state.totalUsage == 200)
    #expect(state.interfaceUsageIsPreserved)
    #expect(state.interfaceUsageReason.contains("采集已暂停"))
    #expect(state.menuBarUsageText == "已保留 \(UsageFormatter.bytes(200))")
    #expect(state.interfaceMenuHelp.contains("采集已暂停"))
    #expect(state.interfaceMenuHelp.contains(client.state.interfaceMessage))
}

@MainActor @Test func unavailableInterfaceMessageAndMissingSampleTimeRemainVisible() async throws {
    let message = "VPN 路由归属不明确，当前接口不可用。"
    for usage in [nil, try interfaceUsage()] {
        let client = FakeAgentClient(monitoring: .collecting, sampledAt: Date(), network: .expensive,
                                     interfaceUsage: usage, interfaceMessage: message)
        let state = AppState(client: client)
        await state.refresh()
        #expect(state.totalUsage == usage?.totalBytes)
        #expect(state.interfaceUsageIsPreserved == (usage != nil))
        #expect(state.interfaceServiceMessage == message)
        #expect(state.interfaceMenuHelp.contains(message))
        #expect(state.interfaceSampleTimeText.contains("尚无有效采样时间"))
        if usage != nil { #expect(state.interfaceUsageReason.contains("保留")) }
    }
}

@MainActor @Test func oldInterfaceSamplePreservesTotalAndShowsItsOwnTime() async throws {
    let sampleTime = Date().addingTimeInterval(-60)
    let client = FakeAgentClient(monitoring: .collecting, sampledAt: Date(), network: .expensive,
                                 interfaceUsage: try interfaceUsage(), interfaceSampledAt: sampleTime,
                                 interfaceMessage: "接口暂不可用，已停止累计。")
    let state = AppState(client: client)
    await state.refresh()
    #expect(state.totalUsage == 200)
    #expect(state.interfaceUsageIsPreserved)
    #expect(state.interfaceSampleTimeText.contains(sampleTime.formatted(date: .abbreviated, time: .standard)))
    #expect(state.interfaceMenuHelp.contains("已停止累计"))
}

@MainActor @Test func validInterfaceZeroCanBeShownWithoutApplicationRows() async throws {
    let client = FakeAgentClient(monitoring: .collecting, network: .expensive,
                                 interfaceUsage: try interfaceUsage(uploaded: 0, downloaded: 0),
                                 interfaceSampledAt: Date())
    let state = AppState(client: client)
    await state.refresh()
    #expect(state.totalUsage == 0)
    #expect(state.interfaceUsageAvailable)
    #expect(!state.interfaceUsageIsPreserved)
}

@MainActor @Test func missingInterfaceTotalDoesNotSuppressApplicationThresholdReminder() async throws {
    let event = try reminder()
    let client = FakeAgentClient(applications: [try application(used: 100)], monitoring: .collecting,
                                 sampledAt: Date(), notifications: [event], network: .expensive)
    let scheduler = FakeReminderScheduler()
    let state = AppState(client: client, scheduler: scheduler)
    await state.refresh()
    #expect(state.totalUsage == nil)
    #expect(scheduler.scheduled == [event.id])
    #expect(client.acknowledgements == [event.key])
}
