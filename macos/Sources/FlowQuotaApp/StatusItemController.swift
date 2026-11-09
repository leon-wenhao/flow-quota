import AppKit
import FlowQuotaCore
import Observation
import SwiftUI

/// Owns the public AppKit status item so secondary clicks can open a native menu.
/// The existing SwiftUI panel and application-lifetime polling remain independent.
@MainActor
final class StatusItemController: NSObject {
    let statusItem: NSStatusItem
    private let state: AppState
    private let openPreferences: (PreferencesNavigation.Page) -> Void
    private let openApplication: (ApplicationSnapshot) -> Void
    private let checkForUpdates: () -> Void
    private let quit: () -> Void
    private let defaults: UserDefaults
    private var stopped = false
    private(set) var panel: NSPopover?

    init(state: AppState, defaults: UserDefaults = .standard,
         openPreferences: @escaping (PreferencesNavigation.Page) -> Void,
         openApplication: @escaping (ApplicationSnapshot) -> Void,
         checkForUpdates: @escaping () -> Void, quit: @escaping () -> Void) {
        self.state = state
        self.defaults = defaults
        self.openPreferences = openPreferences
        self.openApplication = openApplication
        self.checkForUpdates = checkForUpdates
        self.quit = quit
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        let button = statusItem.button
        button?.image = BrandIdentity.menuBarImage
        button?.imagePosition = .imageLeading
        button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button?.target = self
        button?.action = #selector(clicked(_:))
        button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged),
                                               name: UserDefaults.didChangeNotification, object: defaults)
        observePresentation()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        panel?.close()
        NotificationCenter.default.removeObserver(self)
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func observePresentation() {
        guard !stopped else { return }
        withObservationTracking {
            refreshButton()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observePresentation() }
        }
    }

    @objc private func preferencesChanged() { refreshButton() }

    private func refreshButton() {
        guard !stopped, let button = statusItem.button else { return }
        let showUsage = defaults.object(forKey: "showMenuBarUsage") as? Bool ?? true
        button.title = showUsage ? state.menuBarUsageText : ""
        button.alphaValue = state.interfaceUsageAvailable && !state.interfaceUsageIsPreserved ? 1 : 0.55
        button.toolTip = state.interfaceMenuHelp
        button.setAccessibilityLabel(state.menuBarUsageAccessibilityLabel)
        button.setAccessibilityHelp("点按查看用量概览；右键或 Control 点按打开快捷菜单。")
    }

    /// Control-click also uses the system's conventional secondary-click behavior.
    static func isSecondaryClick(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        return event.type == .rightMouseUp
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if Self.isSecondaryClick(NSApplication.shared.currentEvent) {
            panel?.close()
            let menu = makeMenu()
            menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.minX, y: sender.bounds.maxY), in: sender)
        } else {
            togglePanel(relativeTo: sender)
        }
    }

    func togglePanel(relativeTo button: NSView) {
        if let panel, panel.isShown {
            panel.performClose(nil)
            return
        }
        if panel == nil {
            let host = NSHostingController(rootView: PanelView(state: state,
                openPreferences: { [weak self] page in self?.showPreferences(page) },
                openApplication: { [weak self] application in
                    self?.panel?.close()
                    self?.openApplication(application)
                }).appAppearance())
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.contentViewController = host
            popover.contentSize = host.view.fittingSize
            panel = popover
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        panel?.contentViewController?.view.window?.makeKey()
    }

    private func showPreferences(_ page: PreferencesNavigation.Page) {
        panel?.close()
        openPreferences(page)
    }

    private enum Shortcut: Int, CaseIterable {
        case applications, charts, history, general, updates, quit

        var title: String {
            switch self {
            case .applications: "应用用量"
            case .charts: "用量图表"
            case .history: "预警记录"
            case .general: "通用设置"
            case .updates: "检查更新"
            case .quit: "退出并停止采集"
            }
        }
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for shortcut in Shortcut.allCases {
            if shortcut == .general || shortcut == .quit { menu.addItem(.separator()) }
            let item = NSMenuItem(title: shortcut.title, action: #selector(selectedShortcut(_:)), keyEquivalent: "")
            item.tag = shortcut.rawValue
            item.target = self
            switch shortcut {
            case .updates: item.isEnabled = state.updater.canCheck && !state.busy && !state.quitRequested
            case .quit: item.isEnabled = !state.busy && !state.quitRequested
            default: break
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func selectedShortcut(_ item: NSMenuItem) {
        guard item.isEnabled, let shortcut = Shortcut(rawValue: item.tag) else { return }
        switch shortcut {
        case .applications: showPreferences(.applications)
        case .charts: showPreferences(.charts)
        case .history: showPreferences(.history)
        case .general: showPreferences(.general)
        case .updates:
            guard state.updater.canCheck, !state.busy, !state.quitRequested else { return }
            checkForUpdates()
        case .quit:
            guard !state.busy, !state.quitRequested else { return }
            quit()
        }
    }
}
