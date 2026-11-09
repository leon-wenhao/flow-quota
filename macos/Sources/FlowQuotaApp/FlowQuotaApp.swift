import AppKit
import FlowQuotaCore
import UserNotifications

/// AppKit owns the existing status item and single preferences window. Keeping
/// an empty SwiftUI Settings scene here creates a second, blank system window.
@main @MainActor
enum FlowQuotaApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // NSApplication.delegate is weak; retain it throughout the event loop.
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private lazy var monitor = AppMonitor(state: state)
    private let notificationDelegate = ReminderPresentationDelegate()
    lazy var preferences = PreferencesWindowController(state: state)
    private var statusItem: StatusItemController?
    private var applicationMenu: ApplicationMenuController?
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
        let applicationMenu = ApplicationMenuController(
            openPreferences: { [weak self] in self?.preferences.show(.general) },
            quit: { [weak self] in self?.state.requestQuit() })
        self.applicationMenu = applicationMenu
        NSApplication.shared.mainMenu = applicationMenu.menu
        AppAppearancePreference.selection().apply()
        statusItem = StatusItemController(state: state,
            openPreferences: { [weak self] in self?.preferences.show($0) },
            openApplication: { [weak self] in self?.preferences.showApplication($0) },
            checkForUpdates: { [weak self] in self?.state.updater.check() },
            quit: { [weak self] in self?.state.requestQuit() })
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

    func applicationWillTerminate(_ notification: Notification) {
        statusItem?.stop()
        monitor.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
