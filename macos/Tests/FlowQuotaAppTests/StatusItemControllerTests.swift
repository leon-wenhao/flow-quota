import AppKit
import FlowQuotaCore
import Testing
@testable import FlowQuotaApp

/// Native menu and popover checks use fake snapshots; no service or update check is started.
@Suite(.serialized) @MainActor
struct StatusItemControllerTests {
    @Test func secondaryClickIncludesTrackpadAndControlClick() throws {
        func event(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        }
        #expect(StatusItemController.isSecondaryClick(try event(.rightMouseUp)))
        #expect(StatusItemController.isSecondaryClick(try event(.leftMouseUp, modifiers: .control)))
        #expect(!StatusItemController.isSecondaryClick(try event(.leftMouseUp)))
        #expect(!StatusItemController.isSecondaryClick(nil))
    }

    @Test func menuRoutesPagesAndUsesExistingQuitAction() throws {
        _ = NSApplication.shared
        let client = FakeAgentClient(monitoring: .paused)
        let state = AppState(client: client, scheduler: FakeReminderScheduler())
        var pages: [PreferencesNavigation.Page] = []
        var checks = 0
        var quits = 0
        let controller = StatusItemController(state: state,
            openPreferences: { pages.append($0) }, openApplication: { _ in },
            checkForUpdates: { checks += 1 }, quit: { quits += 1 })
        defer { controller.stop() }
        let menu = controller.makeMenu()
        #expect(menu.items.filter(\.isSeparatorItem).count == 2)
        let items = menu.items.filter { !$0.isSeparatorItem }
        #expect(items.map(\.title) == ["应用用量", "用量图表", "预警记录", "通用设置", "检查更新", "退出并停止采集"])
        for item in items.prefix(4) {
            #expect(NSApplication.shared.sendAction(try #require(item.action), to: item.target, from: item))
        }
        #expect(pages == [.applications, .charts, .history, .general])
        let update = try #require(items.first { $0.title == "检查更新" })
        #expect(!update.isEnabled) // Updater was never started; unknown readiness must not enable checks.
        _ = NSApplication.shared.sendAction(try #require(update.action), to: update.target, from: update)
        #expect(checks == 0)
        let quit = try #require(items.last)
        _ = NSApplication.shared.sendAction(try #require(quit.action), to: quit.target, from: quit)
        #expect(quits == 1)
        #expect(client.enabledCount == 0 && client.stoppedCount == 0)
    }

    @Test func busyStateDisablesQuitEvenForAnAlreadyOpenedMenu() async throws {
        _ = NSApplication.shared
        let client = FakeAgentClient(monitoring: .paused)
        client.holdStop = true
        let state = AppState(client: client, scheduler: FakeReminderScheduler())
        var quits = 0
        let controller = StatusItemController(state: state, openPreferences: { _ in },
            openApplication: { _ in }, checkForUpdates: {}, quit: { quits += 1 })
        defer { controller.stop() }
        let previousQuit = try #require(controller.makeMenu().items.last)
        state.stopForTermination { _ in }
        defer { client.stopGate?.resume(); client.stopGate = nil }
        let busyQuit = try #require(controller.makeMenu().items.last)
        #expect(!busyQuit.isEnabled)
        _ = NSApplication.shared.sendAction(try #require(previousQuit.action), to: previousQuit.target, from: previousQuit)
        #expect(quits == 0)
        // Allow the fake stop continuation to be installed before releasing it.
        for _ in 0..<20 where client.stopGate == nil { await Task.yield() }
    }

    @Test func statusItemKeepsUnknownUsageAndRespondsToDisplayPreference() async throws {
        _ = NSApplication.shared
        let suite = "FlowQuotaTests.statusItem.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = FakeAgentClient(monitoring: .collecting, network: .expensive,
                                     interfaceUsage: try interfaceUsage(), interfaceSampledAt: Date())
        let state = AppState(client: client, scheduler: FakeReminderScheduler())
        let controller = StatusItemController(state: state, defaults: defaults,
            openPreferences: { _ in }, openApplication: { _ in }, checkForUpdates: {}, quit: {})
        defer { controller.stop() }
        let button = try #require(controller.statusItem.button)
        #expect(button.title == "—")
        #expect(button.accessibilityLabel()?.contains("Flow Quota") == true)
        defaults.set(false, forKey: "showMenuBarUsage")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        #expect(button.title.isEmpty)
        defaults.set(true, forKey: "showMenuBarUsage")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        #expect(button.title == "—")
        await state.refresh()
        for _ in 0..<5 { await Task.yield() }
        #expect(button.title == "200B")
        #expect(button.toolTip == state.interfaceMenuHelp)
        client.fetchFails = true
        await state.refresh()
        for _ in 0..<5 { await Task.yield() }
        #expect(button.title == "—")
    }

    @Test func primaryClickReusesCompactTransientPanel() throws {
        _ = NSApplication.shared
        let state = AppState(client: FakeAgentClient(monitoring: .paused), scheduler: FakeReminderScheduler())
        let controller = StatusItemController(state: state, openPreferences: { _ in },
            openApplication: { _ in }, checkForUpdates: {}, quit: {})
        defer { controller.stop() }
        // The test runner's status-item window has zero height, so it cannot anchor
        // a visible popover. Exercise the same presenter with a real test window.
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 100, height: 30),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        window.contentView = anchor
        window.makeKeyAndOrderFront(nil)
        controller.togglePanel(relativeTo: anchor)
        let panel = try #require(controller.panel)
        #expect(panel.isShown)
        #expect(panel.behavior == .transient)
        #expect(panel.contentSize.width == 360)
        #expect(panel.contentSize.height <= 680)
        controller.togglePanel(relativeTo: anchor)
        #expect(!panel.isShown)
        controller.togglePanel(relativeTo: anchor)
        #expect(controller.panel === panel)
        #expect(panel.isShown)
    }
}
