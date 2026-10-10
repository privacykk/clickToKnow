import AppKit

/// 菜单栏图标与菜单（快捷键提示 / 权限引导 / 设置 / 退出）。
@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private var settingsWindowController: SettingsWindowController?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        setupMenu()
    }

    private func setupMenu() {
        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "text.magnifyingglass",
                accessibilityDescription: "ClickToKnow"
            )
            image?.isTemplate = true // 菜单栏图标务必 template 渲染，亮暗色下才正常
            button.image = image
            button.toolTip = "ClickToKnow 划词释义"
        }

        let menu = NSMenu()

        let hotkeyItem = NSMenuItem(
            title: "快捷键：⌥⌘K（先选中文字）",
            action: nil,
            keyEquivalent: ""
        )
        menu.addItem(hotkeyItem)

        let permissionItem = NSMenuItem(
            title: "辅助功能权限…",
            action: #selector(openAccessibilitySettings(_:)),
            keyEquivalent: ""
        )
        permissionItem.target = self
        menu.addItem(permissionItem)

        menu.addItem(.separator())

        let prefItem = NSMenuItem(
            title: "设置…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        prefItem.target = self
        menu.addItem(prefItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 ClickToKnow",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func openSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 直达系统设置的辅助功能面板（选词靠模拟 ⌘C，未授权则抓不到文本）
    @objc private func openAccessibilitySettings(_ sender: Any?) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
