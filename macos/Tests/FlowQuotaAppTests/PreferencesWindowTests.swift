import AppKit
import FlowQuotaCore
import SwiftUI
import Testing
@testable import FlowQuotaApp

/// These native window checks use only the fake service and never enable sampling.
@MainActor @Test(arguments: [MonitoringStatus.paused, .collecting])
func preferencesWindowIsMovableResizableAndReusedAfterClosing(monitoring: MonitoringStatus) async throws {
    _ = NSApplication.shared
    let client = FakeAgentClient(monitoring: monitoring)
    let state = AppState(client: client, scheduler: FakeReminderScheduler())
    await state.refresh()
    let controller = PreferencesWindowController(state: state)
    controller.show(.general)
    let window = try #require(controller.window)
    defer { window.close() }
    #expect(window.isMovable)
    #expect(window.styleMask.contains(.titled))
    #expect(window.styleMask.contains(.resizable))
    #expect(window.styleMask.contains(.closable))
    #expect(controller.navigation.page == .general)
    let origin = window.frame.origin
    window.setFrameOrigin(NSPoint(x: origin.x + 20, y: origin.y + 20))
    #expect(window.frame.origin != origin)
    window.close()
    #expect(state.snapshot?.monitoring == monitoring)
    #expect(!state.quitRequested)
    #expect(client.enabledCount == 0 && client.stoppedCount == 0)
    controller.show(.applications)
    #expect(controller.window === window)
    #expect(window.isVisible)
    #expect(controller.navigation.page == .applications)
    controller.show(.reminders)
    #expect(controller.window === window)
    #expect(controller.navigation.page == .reminders)
    #expect(state.snapshot?.monitoring == monitoring)
}

@MainActor @Test func quickPanelIsCompactAndKeepsGeometryDuringFeedback() async throws {
    _ = NSApplication.shared
    let state = AppState(client: FakeAgentClient(monitoring: .paused), scheduler: FakeReminderScheduler())
    await state.refresh()
    let host = NSHostingView(rootView: PanelView(state: state, openPreferences: { _ in }))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 480),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    let size = host.fittingSize
    #expect(size.width == 360)
    #expect(size.height <= 680) // Compact overview plus three fixed-height usage rows.
    state.reportError(String(repeating: "服务错误详情；", count: 100))
    host.layoutSubtreeIfNeeded()
    #expect(host.fittingSize == size)
}

@MainActor @Test func switchingPreferencePagesClearsApplicationEditor() throws {
    let navigation = PreferencesNavigation()
    navigation.application = try application()
    navigation.select(.charts)
    #expect(navigation.page == .charts)
    #expect(navigation.application == nil)
}
