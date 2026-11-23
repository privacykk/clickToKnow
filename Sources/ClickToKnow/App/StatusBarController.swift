import AppKit
import ServiceManagement

/// 菜单栏图标与菜单：快捷键与权限状态在菜单展开时实时刷新，暂停取词 / 开机自启开关，设置入口与退出。
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let statusModel: AppStatusModel
    /// 设置窗口控制器（懒创建复用）
    private var settingsWindowController: SettingsWindowController?

    /// 动态条目：menuWillOpen 时先拉最新状态再回填 title
    private let hotkeyItem = NSMenuItem(title: "快捷键", action: nil, keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "辅助功能权限", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "暂停取词", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "开机自启", action: nil, keyEquivalent: "")
    private let historyItem = NSMenuItem(title: "历史记录…", action: nil, keyEquivalent: "")
    /// 历史窗口控制器（懒创建复用）
    private var historyWindowController: HistoryWindowController?

    /// 「暂停取词」开关回调：AppDelegate 注入，转发给 SelectionMonitor（勾选态来自 statusModel.hotKeyPaused）
    var onTogglePause: ((Bool) -> Void)?

    init(statusModel: AppStatusModel) {
        self.statusModel = statusModel
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        setupMenu()
    }

    /// 构建菜单栏图标与完整菜单
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
        menu.delegate = self

        menu.addItem(hotkeyItem)

        permissionItem.target = self
        permissionItem.action = #selector(handlePermissionItem(_:))
        menu.addItem(permissionItem)

        pauseItem.target = self
        pauseItem.action = #selector(togglePause(_:))
        menu.addItem(pauseItem)

        loginItem.target = self
        loginItem.action = #selector(toggleLoginItem(_:))
        menu.addItem(loginItem)

        menu.addItem(.separator())

        historyItem.target = self
        historyItem.action = #selector(openHistory(_:))
        menu.addItem(historyItem)

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
        refreshDynamicItems() // 首次展开前也有正确内容
    }

    // MARK: - NSMenuDelegate

    /// 菜单即将展开：刷新动态条目（快捷键/权限/勾选态取实时值）
    func menuWillOpen(_ menu: NSMenu) {
        refreshDynamicItems()
    }

    /// 回填动态条目文案与勾选态
    private func refreshDynamicItems() {
        statusModel.refresh()
        hotkeyItem.title = "快捷键：\(statusModel.hotKeyBinding.displayString)（先选中文字）"
        switch statusModel.accessibilityState {
        case .granted:
            permissionItem.title = "辅助功能权限：已授权 ✓"
        case .notGranted:
            permissionItem.title = "辅助功能权限：未授权 — 去授权"
        case .invalidated:
            permissionItem.title = "辅助功能权限：已失效（覆盖安装后签名变更）— 点此修复"
        }
        pauseItem.state = statusModel.hotKeyPaused ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    /// 设置窗口当前是否可见：Dock 唤起判断用，避免把划词结果 NSPanel 误当作用户可见主界面
    var isSettingsWindowVisible: Bool {
        settingsWindowController?.window?.isVisible == true
    }

    /// 打开设置与状态中心（菜单「设置…」与启动时自动展示共用）
    @objc func openSettings(_ sender: Any? = nil) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(statusModel: statusModel)
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 权限条目：失效态就地修复（重置 TCC 条目后重新授权），其余情况直达系统设置面板
    @objc private func handlePermissionItem(_ sender: Any?) {
        if statusModel.accessibilityState == .invalidated {
            statusModel.repairAccessibilityPermission()
        } else {
            SystemSettingsOpener.openAccessibility()
        }
    }

    /// 暂停/恢复取词：实际注销/重注册由 SelectionMonitor 完成，勾选态下次展开菜单时刷新
    @objc private func togglePause(_ sender: Any?) {
        onTogglePause?(!statusModel.hotKeyPaused)
    }

    /// 开机自启（macOS 13+ SMAppService）。裸可执行（swift run）没有 app bundle，
    /// register() 会抛错——捕获后仅记日志，勾选态下次刷新时自动回正。
    @objc private func toggleLoginItem(_ sender: Any?) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                Log.app.info("已关闭开机自启")
            } else {
                try service.register()
                Log.app.info("已开启开机自启")
            }
        } catch {
            Log.app.warning("开机自启切换失败（打包为 .app 后才可用）：\(error.localizedDescription)")
        }
    }

    /// 历史记录（生词本）窗口：懒创建复用
    @objc private func openHistory(_ sender: Any?) {
        if historyWindowController == nil {
            historyWindowController = HistoryWindowController()
        }
        historyWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
