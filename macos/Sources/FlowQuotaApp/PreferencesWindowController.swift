import AppKit
import FlowQuotaCore
import SwiftUI

/// One retained native window: closing it never stops the AppDelegate's polling.
@MainActor
final class PreferencesWindowController: NSWindowController {
    let navigation = PreferencesNavigation()
    private let state: AppState

    init(state: AppState) {
        self.state = state
        super.init(window: nil)
    }

    required init?(coder: NSCoder) { nil }

    func showApplication(_ application: ApplicationSnapshot) {
        show(.applications)
        navigation.application = application
    }

    func show(_ page: PreferencesNavigation.Page = .applications) {
        navigation.select(page)
        if window == nil {
            // The charts page contains a timeline and two directional pies; give the first layout enough viewport to show both.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 800),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Flow Quota 偏好设置"
            window.contentViewController = NSHostingController(
                rootView: PreferencesWindowView(state: state, navigation: navigation))
            window.contentMinSize = NSSize(width: 820, height: 620)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("FlowQuotaPreferences")
            if !window.setFrameUsingName("FlowQuotaPreferences") { window.center() }
            self.window = window
        }
        showWindow(nil)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
