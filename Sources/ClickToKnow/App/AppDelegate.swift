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
    /// LLM 配置变更监听（清空查询缓存，防旧释义串味）
    private var configObserver: NSObjectProtocol?
    private var privacyObserver: NSObjectProtocol?
    /// 历史记录删除 / 清空 / 裁剪监听（淘汰对应内存缓存，关闭正在展示的历史复用结果）
    private var historyRemovalObserver: NSObjectProtocol?
    /// 当前弹窗内容来自哪条历史记录（该记录被删除时要立刻关闭，不能继续展示已删除的释义）
    private var currentReuseSourceID: HistoryEntry.ID?

    /// 查询代际：新查询、关闭弹窗、暂停、展示失败提示都会让旧会话失效，
    /// 过期响应（增量/成功/失败）在落到 UI 前统一校验，不再只靠「成功才换代」。
    private let querySession = QuerySession()

    /// 当前在途的查询任务：发起新查询或关闭弹窗时取消，避免已无人看的请求继续烧 token
    private var currentRequest: Task<Void, Never>?

    /// 进程内查询缓存：同一词条重复查询直接命中，零延迟零费用
    private let cache = InterpretationCache()

    /// regular 策略下必须有主菜单，否则设置页输入框的 ⌘C/⌘V/⌘A 等标准编辑快捷键无处分发
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenuBuilder.make()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 整理旧配置和密钥归属。迁移密钥等到用户在设置页主动操作。
        AppConfig.shared.migrateLegacyConfigIfNeeded()
        // 启动即在后台打开历史库并完成旧 JSON 迁移：别等用户第一次打开历史窗口时才做
        _ = HistoryStore.shared
        statusBarController = StatusBarController(statusModel: statusModel)
        popover = ResultPopover()
        setupSelectionMonitor()
        statusModel.selectionMonitor = selectionMonitor
        statusModel.refresh()
        requestAccessibilityIfNeeded()
        observeHotKeyChanges()
        observeLLMConfigChanges()
        observeHistoryRemovals()
        // 启动即展示主界面：用户打开应用立刻看到配置与状态，而不是只有一枚菜单栏图标
        statusBarController?.openSettings()
        Log.app.info("LLM 配置：\(AppConfig.shared.hasLLMConfig ? "已就绪" : "未配置（回落到系统词典）")")
    }

    /// 退出前把后台排队中的历史记录写完（写入是异步合并的，不 flush 会丢掉最后几条）
    func applicationWillTerminate(_ notification: Notification) {
        if let privacyObserver { NotificationCenter.default.removeObserver(privacyObserver) }
        if let historyRemovalObserver { NotificationCenter.default.removeObserver(historyRemovalObserver) }
        HistoryStore.shared.flush()
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
        // 弹窗关闭（点击外部 / 超时 / Esc）即让在途查询整体失效：
        // 只 cancel 不换代的话，词典路径（Task.detached 不受取消影响）仍会把释义重新弹出来
        popover?.onClose = { [weak self] in
            self?.invalidateCurrentQuery()
        }
        // 菜单栏「暂停取词」开关：暂停期间不应再有在途查询落到 UI
        statusBarController?.onTogglePause = { [weak self] paused in
            self?.invalidateCurrentQuery()
            if paused { self?.popover?.close() }
            self?.selectionMonitor?.setPaused(paused)
            self?.statusModel.refresh()
        }
    }

    /// 让当前查询会话失效并断连：此后任何增量、成功、失败结果都不会落到 UI 或写历史。
    /// 关闭弹窗、暂停取词、新查询、展示取词失败提示都应走这里。
    private func invalidateCurrentQuery() {
        currentRequest?.cancel()
        currentRequest = nil
        currentReuseSourceID = nil
        querySession.invalidate()
    }

    /// LLM 配置变更（增删配置 / 切换生效项 / 改端点模型 / 写清密钥）后清空查询缓存。
    /// 缓存键虽含配置指纹，但「同一配置缺密钥走词典 → 补上密钥走 LLM」这类来源切换
    /// 必须在配置一变就让旧条目失效，不能等指纹自然变化。
    private func observeLLMConfigChanges() {
        configObserver = NotificationCenter.default.addObserver(
            forName: AppConfig.llmConfigChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.invalidateCurrentQuery()
                self?.popover?.close()
                self?.cache.removeAll()
            }
        }
        privacyObserver = NotificationCenter.default.addObserver(
            forName: AppConfig.privacyChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.invalidateCurrentQuery()
                self?.popover?.close()
                self?.cache.removeAll()
                self?.statusModel.refresh()
            }
        }
    }

    /// 历史记录被删除 / 清空 / 自动裁剪：淘汰对应内存缓存；若弹窗正展示那条历史，立即关闭。
    /// 不做这一步，用户删掉记录后仍能命中旧结果，看起来像删除没生效。
    private func observeHistoryRemovals() {
        historyRemovalObserver = NotificationCenter.default.addObserver(
            forName: HistoryStore.didRemoveHistoryNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                let fingerprints = Set(notification.userInfo?["fingerprints"] as? [String] ?? [])
                self.cache.removeEntries(matchingFingerprints: fingerprints)
                let ids = Set(notification.userInfo?["ids"] as? [HistoryEntry.ID] ?? [])
                if let source = self.currentReuseSourceID, ids.contains(source) {
                    self.invalidateCurrentQuery()
                    self.popover?.close()
                }
            }
        }
    }

    /// 抓取失败的可见反馈：按原因给出可操作的提示（此前只写 NSLog，用户按了没反应）
    private func handleSelectionFailure(_ failure: SelectionFailure, at location: NSPoint) {
        // 新一次取词已失败：让上一次查询失效，否则旧响应返回后会把这条提示覆盖成释义
        invalidateCurrentQuery()
        popover?.resetPlacement() // 提示贴新选区，不继承上一次拖动后的位置
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

            当前应用在黑名单中，选中文本不会被抓取。可在「设置 → 隐私」管理自定义条目。
            """
        case .emptySelection:
            message = "**未抓取到文本**：请先选中一段文字再按快捷键。"
        case .timeout:
            message = """
            **抓取超时**

            当前应用复制响应较慢，或禁止复制（部分 PDF / 密码管理器）。
            """
        case .targetChanged:
            message = """
            **已跳过本次查询**

            等待取词期间前台应用已切换。为避免复制到其他应用的内容，本次抓取已取消；请重新选中文字后再按快捷键。
            """
        case .clipboardChangedExternally:
            message = """
            **已取消本次取词**

            等待取词期间你复制了新的内容。为免把这份内容误当作选词发出去，本次取词已取消，剪贴板保持你的最新内容。
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
    /// 流式增量与最终结果都校验会话代际，过期响应一律丢弃。
    private func handleSelectedText(_ text: String, at location: NSPoint, context: String?, bypassCache: Bool = false) {
        invalidateCurrentQuery() // 新查询取代旧查询：旧请求立即断连而非仅丢弃结果
        // 新查询重新贴回选区：同一次查询后续的流式收尾/失败提示走 show 时会保留用户拖动的位置
        popover?.resetPlacement()
        let requestID = querySession.begin()

        // 查询开始时冻结配置：缓存键、Provider、历史归属都取自这一份快照，
        // 中途改配置/切模型不会让「按旧端点请求的结果写进新配置的缓存键」
        let snapshot = ProviderFactory.snapshot()
        let requestContext = snapshot.contextForRequest(context)

        // 缓存键含来源、上下文与配置指纹：换供应商/模型、同词不同上下文、词典与 LLM 之间都不串
        let cacheKey = InterpretationCache.key(
            term: text,
            context: requestContext,
            source: snapshot.source,
            baseURL: snapshot.baseURL,
            model: snapshot.model,
            apiProtocol: snapshot.apiProtocol,
            profileID: snapshot.profileID,
            explanationStyle: snapshot.explanationStyle
        )
        let fingerprint = QueryFingerprint.make(from: cacheKey)
        let retry: () -> Void = { [weak self] in
            // 「重新查询」绕过两层缓存：内存缓存与本地历史都不看一眼，直接请求
            self?.handleSelectedText(text, at: location, context: requestContext, bypassCache: true)
        }
        currentReuseSourceID = nil
        if !bypassCache, let cached = cache.get(cacheKey) {
            guard querySession.isCurrent(requestID) else { return }
            let historyID = recordHistory(cached, snapshot: snapshot, fingerprint: fingerprint)
            show(cached, at: location, historyID: historyID, retry: retry)
            return
        }
        // 内存缓存未命中：看本地历史里是否有条件完全一致的释义（关闭保存历史时一并停用）
        if !bypassCache,
           AppConfig.shared.recordsQueryHistory,
           AppConfig.shared.reusesQueryHistory,
           let entry = HistoryStore.shared.reusableEntry(fingerprint: fingerprint),
           let source = Interpretation.Source(rawValue: entry.source) {
            guard querySession.isCurrent(requestID) else { return }
            currentReuseSourceID = entry.id
            showReused(entry, interpretation: Interpretation(term: entry.term, content: entry.content, source: source),
                       at: location, retry: retry)
            return
        }

        // 立即反馈：否则非流式路径要数秒，期间界面像卡死。
        // 加载态不排自动关闭：流式增量不会刷新倒计时，而网络超时是 45s（单请求 20s），
        // 25s 的兜底会在慢请求上把弹窗关掉，连带取消在途查询。
        // 查询期间的时间上限交给网络层；结果落地后由 show 重新开始阅读倒计时。
        popover?.show(MarkdownRenderer.render("查询中…"), at: location, autoCloseAfter: nil)

        let provider = ProviderFactory.make(snapshot)
        currentRequest = Task { [weak self] in
            do {
                let result: Interpretation
                if snapshot.streamsResults, let streaming = provider as? StreamingInterpretationProvider {
                    // 流式：增量按帧合并后再渲染（每个 delta 都全量解析 Markdown + 测高 + 定位
                    // 在长内容下都是主线程开销）；合并后只更新内容，不重装监视器、不重排倒计时，
                    // 否则悬停暂停每分钟都会被覆盖
                    let coalescer = StreamingCoalescer { [weak self] partial in
                        guard let self, self.querySession.isCurrent(requestID) else { return }
                        self.popover?.updateContent(MarkdownRenderer.render(partial))
                    }
                    result = try await streaming.interpretStreaming(text, context: requestContext) { partial in
                        guard let self, self.querySession.isCurrent(requestID) else { return }
                        coalescer.push(partial)
                    }
                    coalescer.flush()
                } else {
                    result = try await provider.interpret(text, context: requestContext)
                }
                guard let self, self.querySession.isCurrent(requestID) else { return } // 已被新查询/关闭取代
                self.cache.put(cacheKey, result)
                let historyID = self.recordHistory(result, snapshot: snapshot, fingerprint: fingerprint)
                self.show(result, at: location, historyID: historyID, retry: retry)
            } catch is CancellationError {
                // 弹窗已关闭或已被新查询取代：静默丢弃，不展示错误
            } catch {
                guard let self, self.querySession.isCurrent(requestID) else { return }
                let message = (error as? InterpretationError)?.userMessage
                    ?? "查询失败：\(error.localizedDescription)"
                // 日志只记类别与状态码：服务端正文可能回显密钥或选中文本，不写入日志系统
                if let interpretationError = error as? InterpretationError {
                    Log.llm.error("释义失败：\(interpretationError.logCategory)")
                } else {
                    Log.llm.error("释义失败：\(type(of: error))")
                }
                self.showFailure(message, for: text, at: location, retry: retry)
            }
        }
    }

    /// 展示成功释义（Markdown 渲染后入弹窗，自动关闭沿用上次时限）
    private func recordHistory(
        _ result: Interpretation, snapshot: QuerySnapshot, fingerprint: String
    ) -> HistoryEntry.ID? {
        guard AppConfig.shared.recordsQueryHistory else { return nil }
        return HistoryStore.shared.add(result, model: snapshot.historyModel, fingerprint: fingerprint)
    }

    /// 展示来自本地历史的释义：标注来源与时间，不再追加重复记录。
    /// 「重试」按钮走 bypassCache，会真正重新查询。
    private func showReused(
        _ entry: HistoryEntry, interpretation: Interpretation, at location: NSPoint, retry: @escaping () -> Void
    ) {
        let stamp = entry.date.formatted(date: .abbreviated, time: .shortened)
        let body = "_来自本地历史（\(stamp)）_\n\n" + interpretation.content
        popover?.show(
            MarkdownRenderer.render(body), at: location, result: interpretation, retry: retry,
            toggleFavorite: { HistoryStore.shared.toggleFavorite(id: entry.id) }
        )
    }

    private func show(
        _ result: Interpretation, at location: NSPoint, historyID: HistoryEntry.ID?, retry: @escaping () -> Void
    ) {
        popover?.show(MarkdownRenderer.render(result.content), at: location, result: result, retry: retry,
                      toggleFavorite: historyID.map { id in { HistoryStore.shared.toggleFavorite(id: id) } })
    }

    /// 展示失败提示：附设置入口指引，便于自查配置
    private func showFailure(_ message: String, for text: String, at location: NSPoint, retry: @escaping () -> Void) {
        let hint = """
        **未能查询：\(text)**

        \(message)

        ▸ 可在菜单栏「设置…」检查 Base URL / Model / 密钥
        """
        popover?.show(MarkdownRenderer.render(hint), at: location, retry: retry)
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
