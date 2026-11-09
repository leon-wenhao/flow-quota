import AppKit
import Testing
@testable import FlowQuotaApp

/// Fake service only: menu/window regression checks never start actual sampling.
@MainActor @Suite(.serialized) struct ApplicationMenuTests {
    @Test func settingsCommandReusesPopulatedWindowAndReopensAfterClosing() throws {
        _ = NSApplication.shared
        let client = FakeAgentClient(monitoring: .paused)
        let state = AppState(client: client, scheduler: FakeReminderScheduler())
        let preferences = PreferencesWindowController(state: state)
        let commands = ApplicationMenuController(openPreferences: { preferences.show(.general) }, quit: {})
        let applicationMenu = try #require(commands.menu.items.first?.submenu)
        let index = try #require(applicationMenu.items.firstIndex { $0.keyEquivalent == "," })
        applicationMenu.performActionForItem(at: index)
        let window = try #require(preferences.window)
        defer { window.close() }
        #expect(window.title == "Flow Quota 偏好设置")
        #expect(window.contentViewController != nil)
        #expect(preferences.navigation.page == .general)
        applicationMenu.performActionForItem(at: index)
        #expect(preferences.window === window)
        window.close()
        applicationMenu.performActionForItem(at: index)
        #expect(preferences.window === window && window.isVisible)
        #expect(client.enabledCount == 0 && client.stoppedCount == 0)
        #expect(!state.quitRequested)
    }

    @Test func keyboardShortcutsUseSharedSettingsAndSafeQuitCallbacks() throws {
        _ = NSApplication.shared
        var settings = 0
        var quits = 0
        let commands = ApplicationMenuController(openPreferences: { settings += 1 }, quit: { quits += 1 })
        for key in [",", "q"] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: 0, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0))
            #expect(commands.menu.performKeyEquivalent(with: event))
        }
        #expect(settings == 1 && quits == 1)
        let quit = try #require(commands.menu.items.first?.submenu?.items.first { $0.keyEquivalent == "q" })
        #expect(quit.title == "退出并停止采集")
        #expect(quit.action != #selector(NSApplication.terminate(_:)))
    }

    @Test func nativeTextEditingCommandsKeepResponderChainTargets() throws {
        let commands = ApplicationMenuController(openPreferences: {}, quit: {})
        let edit = try #require(commands.menu.items.first { $0.title == "编辑" }?.submenu)
        for key in ["x", "c", "v", "a", "z"] {
            let items = edit.items.filter { $0.keyEquivalent == key }
            #expect(!items.isEmpty)
            #expect(items.allSatisfy { $0.target == nil && $0.action != nil })
        }
    }
}
