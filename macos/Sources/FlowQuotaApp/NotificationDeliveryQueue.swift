import Foundation
import Observation
import UserNotifications

/// Shared bounded schedule/ACK state machine for app quotas and traffic alerts.
/// Successful scheduling is retained in memory while durable ACK is retried.
@MainActor @Observable
final class NotificationDeliveryQueue<Event: Identifiable> where Event.ID == String {
    private(set) var errorMessage: String?
    private(set) var delivering = false
    @ObservationIgnored private var scheduled = Set<String>()
    @ObservationIgnored private var acknowledged = Set<String>()
    @ObservationIgnored private let authorization: @MainActor () async throws -> UNAuthorizationStatus
    @ObservationIgnored private let schedule: @MainActor (Event) async throws -> Void
    @ObservationIgnored private let acknowledge: @MainActor (Event) async throws -> Void
    @ObservationIgnored private let name: @MainActor (Event) -> String

    init(authorization: @escaping @MainActor () async throws -> UNAuthorizationStatus,
         schedule: @escaping @MainActor (Event) async throws -> Void,
         acknowledge: @escaping @MainActor (Event) async throws -> Void,
         name: @escaping @MainActor (Event) -> String) {
        self.authorization = authorization; self.schedule = schedule
        self.acknowledge = acknowledge; self.name = name
    }

    /// MainActor reentrancy allows panel refreshes during scheduling/ACK. Keep one delivery
    /// batch in flight; retry on the next poll, using the service's deterministic request ID.
    func deliver(_ proposals: [Event],
                 isEligible: @MainActor (Event) -> Bool = { _ in true }) async {
        guard !delivering else { return }
        delivering = true
        defer { delivering = false }
        let pending = Set(proposals.map(\.id))
        // Bound memory to the current service queue. Durable receipts live in the Agent.
        scheduled.formIntersection(pending)
        acknowledged.formIntersection(pending)
        guard proposals.contains(where: { !acknowledged.contains($0.id) }) else {
            errorMessage = nil
            return
        }
        do {
            let authorization = try await authorization()
            guard !Task.isCancelled else { return }
            guard authorization == .authorized || authorization == .provisional else {
                errorMessage = authorization == .denied
                    ? "系统已拒绝通知；待发送提醒未确认，请在系统设置中允许通知。"
                    : "通知尚未获授权；待发送提醒未确认，请允许阈值提醒。"
                return
            }
        } catch {
            errorMessage = "无法准备通知：\(error.localizedDescription)"
            return
        }
        var failures: [String] = []
        for notification in proposals where !acknowledged.contains(notification.id) {
            guard !Task.isCancelled, isEligible(notification) else { return }
            do {
                if !scheduled.contains(notification.id) {
                    try await schedule(notification)
                    scheduled.insert(notification.id)
                }
                guard !Task.isCancelled, isEligible(notification) else { return }
                // Never ACK a rejected request. On ACK failure keep the successful scheduling
                // result in memory so another refresh retries only the receipt write.
                try await acknowledge(notification)
                acknowledged.insert(notification.id)
            } catch {
                let stage = scheduled.contains(notification.id) ? "提醒已提交系统，但服务确认失败" : "通知调度失败"
                failures.append("\(name(notification))：\(stage)：\(error.localizedDescription)")
            }
        }
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }
}
