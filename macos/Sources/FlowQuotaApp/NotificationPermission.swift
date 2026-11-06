import Foundation
import Observation
import SwiftUI
import UserNotifications

/// Explicit UI authorization; ReminderDelivery separately schedules real Agent proposals.
@MainActor @Observable
final class NotificationPermission {
    private(set) var status: UNAuthorizationStatus?
    private(set) var alerts: UNNotificationSetting?
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
}

struct NotificationPermissionView: View {
    let permission: NotificationPermission
    @State private var refreshRequest = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label("本地通知", systemImage: "bell")
                Spacer()
                Text(permission.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if permission.available {
                    Button { refreshRequest += 1 } label: {
                        ZStack {
                            if permission.requesting { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "arrow.clockwise") }
                        }
                        .frame(width: 16, height: 16)
                    }
                    .buttonStyle(FlowQuotaIconButtonStyle())
                    .accessibilityLabel("刷新通知授权状态").help("刷新通知授权状态")
                    .disabled(permission.reading || permission.requesting)
                }
            }
            if !permission.available {
                Text("请运行完整 app 以使用系统通知。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if permission.canOfferRequest {
                Button("允许通知") { permission.request() }
                    .settingsAction(prominent: true).disabled(!permission.canRequest)
            } else if permission.status == .denied || permission.alerts == .disabled {
                Label("请在系统设置的通知中开启提醒。", systemImage: "bell.slash")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let error = permission.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .task(id: refreshRequest) { await permission.refresh() }
    }
}
