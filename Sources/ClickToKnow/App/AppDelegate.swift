import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var selectionMonitor: SelectionMonitor?
    private var popover: ResultPopover?
    /// 应用状态聚合模型（状态页数据源）
    private let statusModel = AppStatusModel()
    /// 快捷键绑定变更监听（AppConfig 广播后刷新状态页）
    private var hotKeyObserver: NSObjectProtocol?

    /// 自增请求序号：LLM 响应耗时不定，若两次查询的返回顺序颠倒，
    /// 只展示最新一次的结果，丢弃过期响应。
    private var requestCounter = 0

    /// 当前在途的查询任务：发起新查询或关闭弹窗时取消，避免已无人看的请求继续烧 token
    private var currentRequest: Task<Void, Never>?

    /// 进程内查询缓存：同一词条重复查询直接命中，零延迟零费用
    private let cache = InterpretationCache()

    /// regular 策略下必须有主菜单，否则设置页输入框的 ⌘C/⌘V/⌘A 等标准编辑快捷键无处分发
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenuBuilder.make()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 先做一次性迁移（单配置 → 配置列表、明文密钥 → 钥匙串）再装配 UI，
        // 保证状态页首次展示的就是最终密钥来源
        AppConfig.shared.migrateLegacyConfigIfNeeded()
        statusBarController = StatusBarController(statusModel: statusModel)
        popover = ResultPopover()
        setupSelectionMonitor()
        statusModel.selectionMonitor = selectionMonitor
        statusModel.refresh()
        requestAccessibilityIfNeeded()
        observeHotKeyChanges()
        // 启动即展示主界面：用户打开应用立刻看到配置与状态，而不是只有一枚菜单栏图标
        statusBarController?.openSettings()
        Log.app.info("LLM 配置：\(AppConfig.shared.hasLLMConfig ? "已就绪" : "未配置（回落到系统词典）")")
    }

    /// 点击 Dock 图标 / Finder 重复启动时，若设置窗口不可见则重新打开。
    /// 不能只看 hasVisibleWindows：划词结果 NSPanel 也是窗口，展示期间会挡住 Dock 唤起。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if statusBarController?.isSettingsWindowVisible != true {
            statusBarController?.openSettings()
        }
        return false
    }

    /// 装配选词监听、弹窗关闭回调与菜单栏暂停开关
    private func setupSelectionMonitor() {
        selectionMonitor = SelectionMonitor(
            onSelected: { [weak self] text, location, context in
                self?.handleSelectedText(text, at: location, context: context)
            },
            onFailure: { [weak self] failure, location in
                self?.handleSelectionFailure(failure, at: location)
            }
        )
        selectionMonitor?.start()
        // 弹窗关闭（点击外部 / 超时 / Esc）即取消在途请求
        popover?.onClose = { [weak self] in
            self?.currentRequest?.cancel()
        }
        // 菜单栏「暂停取词」开关
        statusBarController?.onTogglePause = { [weak self] paused in
            self?.selectionMonitor?.setPaused(paused)
            self?.statusModel.refresh()
        }
    }

    /// 抓取失败的可见反馈：按原因给出可操作的提示（此前只写 NSLog，用户按了没反应）
    private func handleSelectionFailure(_ failure: SelectionFailure, at location: NSPoint) {
        let message: String
        switch failure {
        case .noAccessibilityPermission:
            // 覆盖安装换掉二进制后，系统设置里旧条目还在但已失效：给出针对性的修复路径，
            // 否则用户盯着一个「已勾选」的开关无从下手
            statusModel.refresh()
            if statusModel.accessibilityState == .invalidated {
                message = """
                **辅助功能授权已失效**

                系统设置里仍列着 ClickToKnow，但覆盖安装改变了应用签名，旧授权不再匹配当前程序。
                打开「设置 → 状态总览」点「修复授权」（菜单栏的「辅助功能权限」条目也可直接修复）会重建授权记录；
                若仍不生效，请在列表中先关闭再打开开关，或移除条目后重新添加。
                """
            } else {
                message = """
                **未获得辅助功能权限**

                抓取选词需要模拟 ⌘C。请到 系统设置 → 隐私与安全 → 辅助功能 勾选 ClickToKnow（菜单栏「辅助功能权限」条目可直达）。
                若列表里已经勾选却仍不可用（覆盖安装后常见），打开「设置 → 状态总览」点「修复授权」重建授权记录。
                """
            }
        case .secureInputActive:
            message = """
            **已跳过本次查询**

            系统正处于安全输入状态（如密码框），为保护隐私不抓取选词。
            """
        case .blacklistedApp:
            message = """
            **已跳过本次查询**

            当前应用在黑名单中（密码/密钥管理类），选中文本不会被抓取。可用 `defaults write ClickToKnow blacklistedBundleIDs -array <bundleID>` 追加自定义条目。
            """
        case .emptySelection:
            message = "**未抓取到文本**：请先选中一段文字再按快捷键。"
        case .timeout:
            message = """
            **抓取超时**

            当前应用复制响应较慢，或禁止复制（部分 PDF / 密码管理器）。
            """
        }
        popover?.show(MarkdownRenderer.render(message), at: location, autoCloseAfter: 8)
    }

    /// 绑定持久化后同步状态并记日志（热重注册本身已由设置页「试注册先行」流程完成）
    private func observeHotKeyChanges() {
        hotKeyObserver = NotificationCenter.default.addObserver(
            forName: AppConfig.hotKeyBindingChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.statusModel.refresh()
                Log.app.info("快捷键绑定已更新：\(self.statusModel.hotKeyBinding.displayString)")
            }
        }
    }

    /// 选词完成的核心流程：缓存查询 → loading 反馈 → 流式/非流式释义 → 落历史。
    /// 流式增量与最终结果都校验 requestID，过期响应一律丢弃。
    private func handleSelectedText(_ text: String, at location: NSPoint, context: String?) {
        currentRequest?.cancel() // 新查询取代旧查询，旧请求立即断连而非仅丢弃结果
        requestCounter += 1
        let requestID = requestCounter

        // 缓存键含配置指纹：换供应商/模型后旧缓存自然隔离
        let config = AppConfig.shared
        let cacheKey = InterpretationCache.key(
            term: text, baseURL: config.baseURL, model: config.model, apiProtocol: config.apiProtocol
        )
        if let cached = cache.get(cacheKey) {
            show(cached, at: location)
            HistoryStore.shared.add(cached, model: config.hasLLMConfig ? config.model : nil)
            return
        }

        // 立即反馈：否则非流式路径要数秒，期间界面像卡死。
        // 展示时限 25s > 请求超时 20s，保证超时错误能顶替 loading 出现
        popover?.show(MarkdownRenderer.render("查询中…"), at: location, autoCloseAfter: 25)

        // 每次按最新配置装配，改设置后立即生效
        let provider = ProviderFactory.make()
        currentRequest = Task {
            do {
                let result: Interpretation
                if let streaming = provider as? StreamingInterpretationProvider {
                    // 流式：每个增量重渲染弹窗，用户边收边看；onDelta 已在主 actor
                    result = try await streaming.interpretStreaming(text, context: context) { [weak self] partial in
                        guard let self, requestID == self.requestCounter else { return }
                        self.popover?.show(MarkdownRenderer.render(partial), at: location, autoCloseAfter: 25)
                    }
                } else {
                    result = try await provider.interpret(text, context: context)
                }
                guard requestID == self.requestCounter else { return } // 已被更新的查询取代
                self.cache.put(cacheKey, result)
                HistoryStore.shared.add(result, model: config.hasLLMConfig ? config.model : nil)
                self.show(result, at: location)
            } catch is CancellationError {
                // 弹窗已关闭或已被新查询取代：静默丢弃，不展示错误
            } catch {
                guard requestID == self.requestCounter else { return }
                let message = (error as? InterpretationError)?.userMessage
                    ?? "查询失败：\(error.localizedDescription)"
                Log.llm.error("释义失败：\(message)")
                self.showFailure(message, for: text, at: location)
            }
        }
    }

    /// 展示成功释义（Markdown 渲染后入弹窗，自动关闭沿用上次时限）
    private func show(_ result: Interpretation, at location: NSPoint) {
        popover?.show(MarkdownRenderer.render(result.content), at: location)
    }

    /// 展示失败提示：附设置入口指引，便于自查配置
    private func showFailure(_ message: String, for text: String, at location: NSPoint) {
        let hint = """
        **未能查询：\(text)**

        \(message)

        ▸ 可在菜单栏「设置…」检查 Base URL / Model / 密钥
        """
        popover?.show(MarkdownRenderer.render(hint), at: location)
    }

    /// 首次启动弹系统授权框（AX 直读与模拟 ⌘C 都依赖辅助功能权限）。
    /// 授权因覆盖安装签名变更而失效时不弹框：系统只会把用户引到一个已经勾选的开关上，
    /// 正确入口是状态页 / 菜单栏的「修复授权」。
    private func requestAccessibilityIfNeeded() {
        guard statusModel.accessibilityState != .invalidated else {
            Log.app.warning("辅助功能授权已因签名变更失效，可在状态总览点「修复授权」重建")
            return
        }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            Log.app.warning("需要辅助功能权限：系统设置 → 隐私与安全 → 辅助功能，勾选本程序后重启")
        }
    }
}
