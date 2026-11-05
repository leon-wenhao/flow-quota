import Foundation
import Observation
import SwiftUI
import UserNotifications

/// Explicit UI authorization; ReminderDelivery separately schedules real Agent proposals.
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
    var canOfferRequest: Bool {
        available && Self.offersRequest(for: status)
    }
    var canRequest: Bool { canOfferRequest && !requesting && !reading }

    // Routine reads disable the existing button rather than remove it mid-refresh.
    static func offersRequest(for status: UNAuthorizationStatus?) -> Bool {
        status == .notDetermined || status == .provisional
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
            HStack {
                Label("本地通知", systemImage: "bell")
                Spacer()
                Text(permission.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if permission.available {
                HStack {
                    if permission.canOfferRequest {
                        Button("允许通知") { permission.request() }
                            .settingsAction(prominent: true)
                            .disabled(!permission.canRequest)
                    }
                    if permission.status == .denied {
                        Label("请在系统设置的通知中开启。", systemImage: "bell.slash")
                            .font(.caption).foregroundStyle(.orange).lineLimit(1)
                            .help("请在系统设置的通知中开启 Flow Quota 通知。")
                    }
                    Spacer()
                    Button { refreshRequest += 1 } label: {
                        ZStack {
                            if permission.requesting { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "arrow.clockwise") }
                        }
                        .frame(width: 16, height: 16)
                    }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("刷新通知授权状态").help("刷新通知授权状态")
                        .disabled(permission.reading || permission.requesting)
                }
                .frame(height: 28)
            } else {
                Text("请运行完整 app 以使用系统通知。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("通知详情") {
                VStack(alignment: .leading, spacing: 6) {
                    if permission.available {
                        Text("提醒：\(NotificationPermission.settingDescription(permission.alerts)) · 声音：\(NotificationPermission.settingDescription(permission.sounds))")
                    }
                    Text("包括应用每日阈值、接口总量和短时流量预警。请保持主应用运行；关闭面板仍可投递。")
                    Text("可在「系统设置 → 通知 → Flow Quota」调整。授权失败不影响采样，但待发提醒不会确认送达。系统接受请求不保证展示横幅，专注模式可能影响提醒。")
                }
                .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: refreshRequest) { await permission.refresh() }
    }
}
