import FlowQuotaCore
import FlowQuotaPlatform
import UserNotifications

@MainActor protocol ReminderNotificationScheduling {
    func authorizationStatus() async throws -> UNAuthorizationStatus
    func schedule(_ notification: ReminderNotification) async throws
    func schedule(_ alert: TrafficAlertEvent) async throws
}

/// Keeps the existing app-quota contract; both kinds share retry/ACK behavior.
@MainActor final class ReminderDelivery {
    private let queue: NotificationDeliveryQueue<ReminderNotification>
    var errorMessage: String? { queue.errorMessage }
    var delivering: Bool { queue.delivering }

    init(client: any AgentServiceClient, scheduler: any ReminderNotificationScheduling) {
        queue = NotificationDeliveryQueue(authorization: { try await scheduler.authorizationStatus() },
            schedule: { try await scheduler.schedule($0) },
            acknowledge: { try await client.acknowledgeNotification($0.key) }, name: { $0.appName })
    }

    func deliver(_ proposals: [ReminderNotification],
                 isEligible: @MainActor (ReminderNotification) -> Bool = { _ in true }) async {
        await queue.deliver(proposals, isEligible: isEligible)
    }
}

@MainActor final class TrafficAlertDelivery {
    private let queue: NotificationDeliveryQueue<TrafficAlertEvent>
    var errorMessage: String? { queue.errorMessage }
    var delivering: Bool { queue.delivering }

    init(client: any AgentServiceClient, scheduler: any ReminderNotificationScheduling) {
        queue = NotificationDeliveryQueue(authorization: { try await scheduler.authorizationStatus() },
            schedule: { try await scheduler.schedule($0) },
            acknowledge: { try await client.acknowledgeTrafficAlert(id: $0.id) }, name: { $0.sourceName })
    }

    func deliver(_ events: [TrafficAlertEvent],
                 isEligible: @MainActor (TrafficAlertEvent) -> Bool = { _ in true }) async {
        await queue.deliver(events, isEligible: isEligible)
    }
}
