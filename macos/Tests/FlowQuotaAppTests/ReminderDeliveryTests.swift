import Foundation
import FlowQuotaCore
import FlowQuotaPlatform
import Testing
import UserNotifications
@testable import FlowQuotaApp

@MainActor final class FakeReminderScheduler: ReminderNotificationScheduling {
    var status: UNAuthorizationStatus = .authorized
    var fails = false
    var scheduled: [String] = []
    var gate: CheckedContinuation<Void, Never>?
    var holdScheduling = false
    var authorizationGate: CheckedContinuation<Void, Never>?
    var holdAuthorization = false

    func authorizationStatus() async throws -> UNAuthorizationStatus {
        if holdAuthorization { await withCheckedContinuation { authorizationGate = $0 } }
        return status
    }
    var scheduledAlerts: [TrafficAlertEvent] = []
    func schedule(_ alert: TrafficAlertEvent) async throws {
        if fails { throw PlatformError.unavailable("test scheduling failure") }
        if holdScheduling { await withCheckedContinuation { gate = $0 } }
        scheduledAlerts.append(alert)
    }
    func schedule(_ notification: ReminderNotification) async throws {
        if fails { throw PlatformError.unavailable("test scheduling failure") }
        if holdScheduling { await withCheckedContinuation { gate = $0 } }
        scheduled.append(notification.id)
    }
}

func reminder(kind: QuotaNotificationKind = .blocked) throws -> ReminderNotification {
    ReminderNotification(key: QuotaNotificationKey(identity: try QuotaIdentity(
        appKey: "signed.test", day: LocalDay.key(for: Date(), in: .current), ruleVersion: 1), kind: kind),
        appName: "Test app", usedBytes: 100, limitBytes: 100)
}

@MainActor @Test func successfulSchedulingAcknowledgesAndRepeatedSnapshotDoesNotRepeat() async throws {
    let client = FakeAgentClient()
    let scheduler = FakeReminderScheduler()
    let delivery = ReminderDelivery(client: client, scheduler: scheduler)
    let event = try reminder()
    await delivery.deliver([event])
    await delivery.deliver([event])
    #expect(scheduler.scheduled == [event.id])
    #expect(client.acknowledgements == [event.key])
    #expect(delivery.errorMessage == nil)
}

@MainActor @Test func deniedOrUnrequestedPermissionNeverSchedulesOrAcknowledges() async throws {
    for status in [UNAuthorizationStatus.denied, .notDetermined] {
        let client = FakeAgentClient()
        let scheduler = FakeReminderScheduler()
        scheduler.status = status
        let delivery = ReminderDelivery(client: client, scheduler: scheduler)
        await delivery.deliver([try reminder()])
        #expect(scheduler.scheduled.isEmpty)
        #expect(client.acknowledgements.isEmpty)
        #expect(delivery.errorMessage != nil)
        scheduler.status = .authorized
        await delivery.deliver([try reminder()])
        #expect(client.acknowledgements.count == 1)
        #expect(delivery.errorMessage == nil)
    }
}

@MainActor @Test func schedulingFailureIsVisibleAndNeverAcknowledges() async throws {
    let client = FakeAgentClient()
    let scheduler = FakeReminderScheduler()
    scheduler.fails = true
    let delivery = ReminderDelivery(client: client, scheduler: scheduler)
    await delivery.deliver([try reminder()])
    #expect(client.acknowledgements.isEmpty)
    #expect(delivery.errorMessage?.contains("调度失败") == true)
    scheduler.fails = false
    await delivery.deliver([try reminder()])
    #expect(client.acknowledgements.count == 1)
    #expect(delivery.errorMessage == nil)
}

@MainActor @Test func acknowledgementFailureRetriesReceiptWithoutSchedulingTwice() async throws {
    let client = FakeAgentClient()
    client.acknowledgementFails = true
    let scheduler = FakeReminderScheduler()
    let delivery = ReminderDelivery(client: client, scheduler: scheduler)
    let event = try reminder()
    await delivery.deliver([event])
    #expect(client.acknowledgements.isEmpty)
    #expect(delivery.errorMessage?.contains("确认失败") == true)
    client.acknowledgementFails = false
    await delivery.deliver([event])
    #expect(scheduler.scheduled == [event.id])
    #expect(client.acknowledgements == [event.key])
    #expect(delivery.errorMessage == nil)
}

@MainActor @Test func panelRefreshCannotDuplicateDeliveryWhileSchedulerIsSuspended() async throws {
    let client = FakeAgentClient()
    let scheduler = FakeReminderScheduler()
    scheduler.holdScheduling = true
    let delivery = ReminderDelivery(client: client, scheduler: scheduler)
    let event = try reminder()
    let task = Task { await delivery.deliver([event]) }
    let deadline = ContinuousClock.now + .seconds(2)
    while scheduler.gate == nil && ContinuousClock.now < deadline { await Task.yield() }
    #expect(scheduler.gate != nil)
    await delivery.deliver([event])
    #expect(client.acknowledgements.isEmpty)
    scheduler.gate?.resume()
    await task.value
    #expect(scheduler.scheduled == [event.id])
    #expect(client.acknowledgements == [event.key])
}

@MainActor @Test func nativeRequestUsesDeterministicIDAndThresholdWording() throws {
    let event = try reminder()
    let request = SystemReminderScheduler.request(for: event)
    #expect(request.identifier == event.id)
    #expect(request.trigger == nil)
    #expect(request.content.title == "已达到每日提醒阈值")
    #expect(!request.content.body.contains("阻断"))
    #expect(request.content.body.contains("Test app"))
    #expect(request.content.body.contains("高成本／手动热点观测用量"))
    #expect(request.content.body.contains("连接继续"))
    #expect(SystemReminderScheduler.request(for: try reminder(kind: .warning)).content.title == "接近每日提醒阈值")
}
