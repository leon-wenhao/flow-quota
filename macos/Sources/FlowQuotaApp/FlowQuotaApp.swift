import AppKit
import FlowQuotaCore
import SwiftUI
import ServiceManagement
import UserNotifications

@main
struct FlowQuotaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var state: AppState { delegate.state }
    @AppStorage("showMenuBarUsage") private var showMenuBarUsage = true

    var body: some Scene {
        MenuBarExtra {
            PanelView(state: state, openPreferences: { delegate.preferences.show($0) },
                      openApplication: { delegate.preferences.showApplication($0) })
                .appAppearance()
        } label: {
            HStack(spacing: 2) {
                Image(nsImage: BrandIdentity.menuBarImage)
                    .opacity(state.interfaceUsageAvailable && !state.interfaceUsageIsPreserved ? 1 : 0.55)
                if showMenuBarUsage { Text(state.menuBarUsageText).monospacedDigit() }
            }
            .accessibilityLabel(state.menuBarUsageAccessibilityLabel)
            .help(state.interfaceMenuHelp)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("偏好设置…") { delegate.preferences.show(.general) }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .appTermination) {
                Button("退出并停止采集") { state.requestQuit() }
                    .keyboardShortcut("q")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private lazy var monitor = AppMonitor(state: state)
    private let notificationDelegate = ReminderPresentationDelegate()
    lazy var preferences = PreferencesWindowController(state: state)
    private var waitingForStop = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if DevelopmentServiceCheck.startIfRequested() { return }
        AppAppearancePreference.selection().apply()
        if state.notifications.available {
            UNUserNotificationCenter.current().delegate = notificationDelegate
        }
        monitor.start()
        guard ProcessInfo.processInfo.arguments.contains("--window") else { return }
        preferences.show()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A first launch with no registered service has no collector to stop. Do not
        // trap the user in an app that has never been enabled.
        if !state.everConnected, !state.busy,
           SMAppService.agent(plistName: FlowQuotaCore.AgentEndpoint.launchAgentPlist).status == .notRegistered {
            return .terminateNow
        }
        guard !waitingForStop else { return .terminateLater }
        waitingForStop = true
        // Reply asynchronously after applicationShouldTerminate has returned terminateLater.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.state.stopForTermination { [weak self] allowed in
                if allowed {
                    self?.waitingForStop = false
                    sender.reply(toApplicationShouldTerminate: true)
                } else {
                    let alert = NSAlert()
                    alert.messageText = "尚未退出 Flow Quota"
                    alert.informativeText = self?.state.errorMessage ?? "本地服务尚未确认停止采集。请重试。"
                    alert.addButton(withTitle: "返回应用")
                    alert.addButton(withTitle: "仅退出界面")
                    alert.informativeText += "\n也可以仅退出界面；后台采集是否仍在运行无法确认，且界面退出后不会发送提醒。"
                    let exitUI = alert.runModal() == .alertSecondButtonReturn
                    self?.waitingForStop = false
                    sender.reply(toApplicationShouldTerminate: exitUI)
                }
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) { monitor.stop() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
