import AppKit
import FlowQuotaCore
import SwiftUI
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
    private lazy var quitProgress = QuitProgressWindow(state: state)
    private lazy var quit = AppQuitCoordinator(state: state,
        suspendPolling: { [weak self] in self?.monitor.stop() },
        resumePolling: { [weak self] in self?.monitor.start() },
        showProgress: { [weak self] in self?.quitProgress.show() },
        hideProgress: { [weak self] in self?.quitProgress.close() },
        confirmUIExit: Self.confirmUIExit,
        terminate: { NSApplication.shared.terminate(nil) })

    func applicationDidFinishLaunching(_ notification: Notification) {
        if DevelopmentServiceCheck.startIfRequested() { return }
        AppAppearancePreference.selection().apply()
        if state.notifications.available {
            UNUserNotificationCenter.current().delegate = notificationDelegate
        }
        Task { @MainActor [self] in
            await state.updater.start(canPrepare: { [weak self] in self?.state.busy == false },
                suspend: { [weak self] in self?.monitor.stop() },
                resume: { [weak self] in self?.monitor.start() },
                showRecovery: { [weak self] in self?.preferences.show(.general) })
            monitor.start()
        }
        guard ProcessInfo.processInfo.arguments.contains("--window") else { return }
        preferences.show()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if state.updater.readyToTerminate || quit.readyToTerminate { return .terminateNow }
        if quit.stopping { return requestQuit(sender) }
        if state.updater.installing || state.updater.recovering || state.updater.needsRecovery {
            let alert = NSAlert()
            alert.messageText = "更新交接尚未完成"
            alert.informativeText = state.updater.errorMessage ?? "请等待安装准备完成，或到软件更新中恢复服务状态。"
            alert.runModal()
            return .terminateCancel
        }

        if state.updater.hasStagedUpdate {
            guard !waitingForStop else { return .terminateLater }
            waitingForStop = true
            Task { @MainActor [self] in
                let allowed = await state.updater.prepareForTermination()
                waitingForStop = false
                if !allowed { preferences.show(.general) }
                sender.reply(toApplicationShouldTerminate: allowed)
            }
            return .terminateLater
        }

        return requestQuit(sender)
    }

    private func requestQuit(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppQuitCoordinator.needsSystemReply(for: NSAppleEventManager.shared().currentAppleEvent) {
            return quit.request(systemReply: { sender.reply(toApplicationShouldTerminate: $0) })
        }
        return quit.request()
    }

    private static func confirmUIExit(_ message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "无法确认采集已停止"
        alert.informativeText = message
        alert.informativeText += "\n仅退出界面后，后台采集可能继续运行，且不会发送提醒。"
        alert.addButton(withTitle: "返回应用")
        alert.addButton(withTitle: "仅退出界面")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func applicationWillTerminate(_ notification: Notification) { monitor.stop() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
