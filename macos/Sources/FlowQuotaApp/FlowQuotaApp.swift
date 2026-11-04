import AppKit
import SwiftUI

@main
struct FlowQuotaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var state: AppState { delegate.state }
    @AppStorage("showMenuBarUsage") private var showMenuBarUsage = true

    var body: some Scene {
        MenuBarExtra {
            PanelView(state: state)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: state.usageAvailable ? "shield" : "shield.slash")
                if showMenuBarUsage { Text(UsageFormatter.bytes(state.totalUsage)) }
            }
            .accessibilityLabel("Flow Quota，今日热点用量\(UsageFormatter.bytes(state.totalUsage))")
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("退出并停止保护") { state.requestQuit() }
                    .keyboardShortcut("q")
            }
        }
        Settings { PanelView(state: state, showSettings: true) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var verificationWindow: NSWindow?
    private var waitingForStop = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.arguments.contains("--window") else { return }
        let window = NSWindow(contentViewController: NSHostingController(rootView: PanelView(state: state)))
        window.title = "Flow Quota"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        verificationWindow = window
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard state.everConnected || state.busy else { return .terminateNow }
        guard !waitingForStop else { return .terminateLater }
        waitingForStop = true
        // Reply asynchronously after applicationShouldTerminate has returned terminateLater.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.state.stopForTermination { [weak self] allowed in
                self?.waitingForStop = false
                sender.reply(toApplicationShouldTerminate: allowed)
                if !allowed {
                    let alert = NSAlert()
                    alert.messageText = "尚未退出 Flow Quota"
                    alert.informativeText = self?.state.errorMessage ?? "本地服务尚未确认停止保护。请重试。"
                    alert.addButton(withTitle: "返回应用")
                    alert.runModal()
                }
            }
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
