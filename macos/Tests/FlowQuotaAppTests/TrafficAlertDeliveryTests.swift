import Foundation
import FlowQuotaCore
import Testing
import UserNotifications
@testable import FlowQuotaApp

func trafficEvent(kind: TrafficAlertKind = .interfaceBurst) throws -> TrafficAlertEvent {
    TrafficAlertEvent(day: try LocalDay.key(for: Date(), in: .current), kind: kind,
        sourceKey: kind == .applicationBurst ? "exec:/usr/libexec/nsurlsessiond" : "",
        sourceName: kind == .applicationBurst ? "nsurlsessiond" : "本机计量接口",
        observedBytes: 12_000_000_000, thresholdBytes: 200_000_000,
        windowSeconds: kind == .dailyInterface ? 0 : TrafficAlertPolicy.initial.windowSeconds,
        observedSeconds: kind == .dailyInterface ? 0 : 2, policyVersion: 1, occurredAt: Date())
}

@MainActor @Test func alertSchedulingACKRetryDoesNotScheduleTwice() async throws {
    let client = FakeAgentClient()
    let scheduler = FakeReminderScheduler()
    let queue = TrafficAlertDelivery(client: client, scheduler: scheduler)
    let event = try trafficEvent()
    client.acknowledgementFails = true
    await queue.deliver([event])
    #expect(scheduler.scheduledAlerts.map(\.id) == [event.id])
    #expect(client.alertAcknowledgements.isEmpty)
    #expect(queue.errorMessage?.contains("确认失败") == true)
    client.acknowledgementFails = false
    await queue.deliver([event])
    await queue.deliver([event])
    #expect(scheduler.scheduledAlerts.count == 1)
    #expect(client.alertAcknowledgements == [event.id])
}

@MainActor @Test func alertAuthorizationAndSchedulingFailureCannotAcknowledge() async throws {
    for denied in [true, false] {
        let client = FakeAgentClient()
        let scheduler = FakeReminderScheduler()
        scheduler.status = denied ? .denied : .authorized
        scheduler.fails = !denied
        let queue = TrafficAlertDelivery(client: client, scheduler: scheduler)
        await queue.deliver([try trafficEvent()])
        #expect(scheduler.scheduledAlerts.isEmpty)
        #expect(client.alertAcknowledgements.isEmpty)
        #expect(queue.errorMessage != nil)
    }
}

@MainActor @Test func pausingWhilePreparingAlertStopsScheduling() async throws {
    let client = FakeAgentClient()
    let scheduler = FakeReminderScheduler()
    scheduler.holdAuthorization = true
    let queue = TrafficAlertDelivery(client: client, scheduler: scheduler)
    var eligible = true
    let event = try trafficEvent()
    let task = Task { await queue.deliver([event], isEligible: { _ in eligible }) }
    while scheduler.authorizationGate == nil { await Task.yield() }
    eligible = false
    scheduler.authorizationGate?.resume()
    await task.value
    #expect(scheduler.scheduledAlerts.isEmpty)
    #expect(client.alertAcknowledgements.isEmpty)
}

@MainActor @Test func trafficAlertNotificationExplainsActualIntervalAndUnconfirmedSource() throws {
    let request = SystemReminderScheduler.request(for: try trafficEvent(kind: .applicationBurst))
    #expect(request.content.body.contains("连续观测 2 秒"))
    #expect(request.content.body.contains("原始请求方未必可确认"))
    #expect(request.content.body.contains("12 GB"))
    #expect(!request.content.body.contains("已阻断"))
    let total = SystemReminderScheduler.request(for: try trafficEvent(kind: .dailyInterface))
    #expect(total.content.body.contains("今日累计"))
    #expect(total.content.body.contains("来源未确认"))
}

@Test func trafficAlertDraftRejectsInvalidEnabledInputAndSupportsAllOff() throws {
    var draft = TrafficAlertDraft(.initial)
    draft.dailyMB = "0"
    #expect(draft.policy == nil)
    draft.dailyEnabled = false; draft.interfaceEnabled = false; draft.applicationEnabled = false
    #expect(draft.policy?.dailyInterfaceBytes == nil)
    #expect(draft.policy?.applicationBurstBytes == nil)
    #expect(draft.policy?.version == 2)
    draft.interfaceEnabled = true; draft.interfaceMB = "0.000001"
    #expect(draft.policy?.interfaceBurstBytes == 1)
}

@Test func trafficAlertDraftUsesThreeMinuteDefaultAndPreservesSavedWindow() throws {
    #expect(TrafficAlertPolicy.initial.windowSeconds == 180)
    #expect(TrafficAlertDraft(.initial).windowMinutes == 3)
    let usingDefault = try TrafficAlertPolicy(dailyInterfaceBytes: nil, interfaceBurstBytes: nil,
        applicationBurstBytes: nil, version: 1)
    #expect(usingDefault.windowSeconds == 180)
    let saved = try TrafficAlertPolicy(dailyInterfaceBytes: nil, interfaceBurstBytes: 1_000_000,
        applicationBurstBytes: nil, windowSeconds: 300, version: 7)
    let draft = TrafficAlertDraft(saved)
    #expect(draft.windowMinutes == 5)
    #expect(draft.policy?.windowSeconds == 300)
    #expect(draft.policy?.version == 8)
}
