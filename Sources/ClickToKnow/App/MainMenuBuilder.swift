import AppKit

/// 程序化构建主菜单：`.regular` 激活策略下，文本编辑快捷键（⌘C/⌘V/⌘X/⌘A/⌘Z）
/// 依靠主菜单里的标准 selector 沿响应链分发；没有主菜单时设置页输入框无法复制粘贴 API Key，
/// ⌘Q/⌘W/⌘H 等标准菜单命令也缺失。
enum MainMenuBuilder {
    static func make(appName: String = "ClickToKnow") -> NSMenu {
        let mainMenu = NSMenu()

        mainMenu.addItem(appMenuItem(appName: appName))
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(windowMenuItem())

        return mainMenu
    }

    private static func appMenuItem(appName: String) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: appName)
        item.submenu = menu
        menu.addItem(
            withTitle: "关于 \(appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "隐藏 \(appName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = menu.addItem(
            withTitle: "隐藏其他",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(
            withTitle: "显示全部",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "退出 \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        return item
    }

    /// 编辑菜单条目 target 保持 nil：沿响应链交给当前文本控件（SwiftUI TextField 亦走此路径）
    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "编辑")
        item.submenu = menu
        menu.addItem(withTitle: "撤销", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "重做", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return item
    }

    private static func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "窗口")
        item.submenu = menu
        menu.addItem(
            withTitle: "最小化",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        menu.addItem(
            withTitle: "关闭窗口",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        NSApp.windowsMenu = menu
        return item
    }
}
