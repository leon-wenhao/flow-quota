import AppKit

/// Application menu commands share the same window and safe quit callbacks as
/// the status item. No separate SwiftUI Settings scene owns another window.
@MainActor final class ApplicationMenuController: NSObject {
    let menu = NSMenu()
    private let openPreferences: () -> Void
    private let quit: () -> Void

    init(openPreferences: @escaping () -> Void, quit: @escaping () -> Void) {
        self.openPreferences = openPreferences
        self.quit = quit
        super.init()

        let applicationMenu = NSMenu(title: "Flow Quota")
        add("偏好设置…", action: #selector(showPreferences), key: ",", to: applicationMenu, target: self)
        applicationMenu.addItem(.separator())
        add("隐藏 Flow Quota", action: #selector(NSApplication.hide(_:)), key: "h", to: applicationMenu)
        let hideOthers = add("隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)),
                             key: "h", to: applicationMenu)
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        add("显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), key: "", to: applicationMenu)
        applicationMenu.addItem(.separator())
        add("退出并停止采集", action: #selector(requestQuit), key: "q", to: applicationMenu, target: self)
        submenu(applicationMenu)

        let edit = NSMenu(title: "编辑")
        // Nil targets route standard editing commands to the focused control.
        add("撤销", action: Selector(("undo:")), key: "z", to: edit)
        let redo = add("重做", action: Selector(("redo:")), key: "z", to: edit)
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        add("剪切", action: #selector(NSText.cut(_:)), key: "x", to: edit)
        add("拷贝", action: #selector(NSText.copy(_:)), key: "c", to: edit)
        add("粘贴", action: #selector(NSText.paste(_:)), key: "v", to: edit)
        add("全选", action: #selector(NSText.selectAll(_:)), key: "a", to: edit)
        submenu(edit)
    }

    private func submenu(_ child: NSMenu) {
        let item = NSMenuItem(title: child.title, action: nil, keyEquivalent: "")
        item.submenu = child
        menu.addItem(item)
    }

    @discardableResult private func add(_ title: String, action: Selector, key: String,
                                       to menu: NSMenu, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        menu.addItem(item)
        return item
    }

    @objc private func showPreferences() { openPreferences() }
    @objc private func requestQuit() { quit() }
}
