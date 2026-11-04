import Foundation
import Observation
import SwiftUI
import UserNotifications

/// UI authorization only. The protection service owns notification content, deduplication and delivery.
@MainActor @Observable
final class NotificationPermission {
    private(set) var status: UNAuthorizationStatus?
    private(set) var alerts: UNNotificationSetting?
    private(set) var sounds: UNNotificationSetting?
    private(set) var reading = false
    private(set) var requesting = false
    private(set) var errorMessage: String?

    // UNUserNotificationCenter.current() requires a real application identity. A raw SwiftPM
    // executable is useful for UI inspection but must not pretend to have notification support.
    var available: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }
    var canRequest: Bool {
        available && !requesting && !reading && (status == .notDetermined || status == .provisional)
    }
    var description: String {
        guard available else { return "需要完整 app 包" }
        switch status {
        case .notDetermined: return "尚未请求授权"
        case .denied: return "系统已拒绝"
        case .authorized: return "已获授权"
        case .provisional: return "临时授权"
        case nil: return "尚未读取"
        @unknown default: return "未知授权状态"
        }
    }

    func refresh() async {
        guard available, !reading else { return }
        reading = true
        defer { reading = false }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard !Task.isCancelled else { return }
        status = settings.authorizationStatus
        alerts = settings.alertSetting
        sounds = settings.soundSetting
    }

    /// Called exclusively by an explicit button; reading settings never requests permission.
    func request() {
        guard canRequest else { return }
        requesting = true
        errorMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.requesting = false }
            do {
                // The returned Boolean is not a delivery guarantee. Re-read the actual settings.
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            } catch { self.errorMessage = "无法请求通知授权：\(error.localizedDescription)" }
            await self.refresh()
        }
    }

    static func settingDescription(_ setting: UNNotificationSetting?) -> String {
        switch setting {
        case .enabled: return "已开启"
        case .disabled: return "已关闭"
        case .notSupported: return "系统不支持"
        case nil: return "未知"
        @unknown default: return "未知"
        }
    }
}

struct NotificationPermissionView: View {
    let permission: NotificationPermission
    @State private var refreshRequest = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("本地通知：\(permission.description)", systemImage: "bell.badge")
            if permission.available {
                Text("提醒：\(NotificationPermission.settingDescription(permission.alerts)) · 声音：\(NotificationPermission.settingDescription(permission.sounds))")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("允许额度提醒", systemImage: "bell") { permission.request() }
                        .disabled(!permission.canRequest)
                    Button("刷新授权状态", systemImage: "arrow.clockwise") { refreshRequest += 1 }
                        .disabled(permission.reading || permission.requesting)
                }
            } else {
                Text("请运行完整 Flow Quota.app 后查看或请求系统通知权限。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if permission.reading || permission.requesting {
                ProgressView(permission.requesting ? "正在等待系统授权结果" : "正在读取通知设置")
                    .controlSize(.small).font(.caption)
            }
            if let error = permission.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
            if permission.status == .denied || permission.status == .authorized {
                Text("可在「系统设置 → 通知 → Flow Quota」调整。拒绝通知不影响计量与阻断。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("此操作只配置系统权限。真实额度事件由本地服务发送；授权成功不代表通知送达或网络阻断已通过验证。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: refreshRequest) { await permission.refresh() }
    }
}
