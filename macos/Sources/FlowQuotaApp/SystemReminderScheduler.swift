import Foundation
import FlowQuotaCore
import UserNotifications

/// macOS 14+, Swift 6. Native UserNotifications delivery belongs to the signed app identity.
/// Apple API references: UNUserNotificationCenter.add(_:withCompletionHandler:),
/// UNNotificationRequest.identifier, and UNUserNotificationCenterDelegate.willPresent.
/// https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app
@MainActor struct SystemReminderScheduler: ReminderNotificationScheduling {
    func authorizationStatus() async throws -> UNAuthorizationStatus {
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else {
            throw SchedulingError.appBundleRequired
        }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func schedule(_ notification: ReminderNotification) async throws {
        try await UNUserNotificationCenter.current().add(Self.request(for: notification))
    }

    func schedule(_ alert: TrafficAlertEvent) async throws {
        try await UNUserNotificationCenter.current().add(Self.request(for: alert))
    }

    static func request(for alert: TrafficAlertEvent) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "\(alert.category.title) · \(alert.kind.title)"
        let interval = alert.kind == .dailyInterface ? "今日累计"
            : "最近最多 \(alert.windowSeconds / 60) 分钟内（连续观测 \(alert.observedSeconds) 秒）"
        let classification = SystemProcessClassification(identity: AppIdentity(key: alert.sourceKey, name: alert.sourceName))
        let source = alert.kind == .applicationBurst ? "\(classification.displayName)（应用/服务归因，原始请求方未必可确认）"
            : "本机计量接口（来源未确认）"
        content.body = "\(source)：\(interval)上传＋下载 \(UsageFormatter.bytes(alert.observedBytes))，阈值 \(UsageFormatter.bytes(alert.thresholdBytes))。仅提醒，连接继续；不等于运营商账单。"
        content.sound = .default
        return UNNotificationRequest(identifier: "flowquota:traffic:\(alert.id)", content: content, trigger: nil)
    }

    static func request(for notification: ReminderNotification) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        // `.blocked` is a legacy persistence key. This app only reports threshold crossings.
        content.title = "\(notification.key.category.title) · " + (notification.key.kind == .blocked ? "已达到每日提醒阈值" : "接近每日提醒阈值")
        content.body = "\(notification.appName)：今日\(notification.key.category.title)观测用量 \(UsageFormatter.bytes(notification.usedBytes))，提醒阈值 \(UsageFormatter.bytes(notification.limitBytes))。仅作提醒，连接继续。"
        content.sound = .default
        // Apple replaces a still-pending request with the same identifier. A crash between
        // scheduling and durable ACK may nevertheless present again; no exactly-once promise.
        return UNNotificationRequest(identifier: notification.id, content: content, trigger: nil)
    }

    private enum SchedulingError: LocalizedError {
        case appBundleRequired
        var errorDescription: String? { "通知需要完整的 Flow Quota.app，请从应用包启动。" }
    }
}

/// Retained by AppDelegate: foreground panels should receive the same real threshold alerts.
final class ReminderPresentationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
