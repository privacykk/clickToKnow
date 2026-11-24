import AppKit
import Carbon.HIToolbox

/// 抓取失败的分类：AppDelegate 据此给出可操作的弹窗提示，不再静默写日志
enum SelectionFailure {
    /// 未授予辅助功能权限（模拟 ⌘C 被系统拦截，必然抓不到）
    case noAccessibilityPermission
    /// 系统处于安全输入态（密码框等），为保护隐私主动跳过
    case secureInputActive
    /// 前台应用在黑名单中（密码/密钥管理类），永不抓取
    case blacklistedApp
    /// 复制成功但内容为空（空选择）
    case emptySelection
    /// 500ms 内剪贴板无变化（应用复制响应慢或禁止复制）
    case timeout
    /// 等待期间前台应用已切换：宁可失败，也不去读别处的内容
    case targetChanged
}

/// 监听全局快捷键，抓取前台应用当前选中的文本。
/// 主路径：AX 直读（不碰剪贴板，顺带选区矩形与前后文）；
/// 兜底：保存剪贴板快照 → 模拟 ⌘C → 轮询 changeCount → 读剪贴板 → 条件恢复。
///
/// 时序约定（这两条是历史缺陷的修复点）：
/// 1. AX 读取全程异步，主线程不阻塞；读取期间的新按键直接丢弃（有界并发）。
/// 2. 剪贴板兜底是一个事务：快照 → 复制 → 读取 → 恢复，**互斥一直持有到恢复完成**，
///    否则第二次查询会在恢复前保存快照，把第一次复制的词条当成用户的原始剪贴板。
@MainActor
final class SelectionMonitor {
    /// 一次取词的目标快照：兜底前后都用它复核「还是不是同一个应用、还是不是隐私安全状态」
    struct Target {
        let pid: pid_t?
        let bundleID: String?
    }

    /// 系统依赖注入点：单测替换后不触碰真实辅助功能授权、剪贴板与前台应用
    struct Environment {
        var isAccessibilityTrusted: () -> Bool
        var isSecureInputEnabled: () -> Bool
        var frontmostBundleID: () -> String?
        var frontmostPID: () -> pid_t?
        var blacklistedBundleIDs: () -> Set<String>
        var mouseLocation: () -> NSPoint
        /// 向前台应用发 ⌘C
        var simulateCopy: () -> Void

        static let live = Environment(
            isAccessibilityTrusted: { AXIsProcessTrusted() },
            isSecureInputEnabled: { IsSecureEventInputEnabled() },
            frontmostBundleID: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            blacklistedBundleIDs: { AppConfig.shared.blacklistedBundleIDs },
            mouseLocation: { NSEvent.mouseLocation },
            simulateCopy: {
                let source = CGEventSource(stateID: .hidSystemState)
                let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
                down?.flags = .maskCommand
                down?.post(tap: .cghidEventTap)
                let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
                up?.flags = .maskCommand
                up?.post(tap: .cghidEventTap)
            }
        )
    }

    private let hotKey = GlobalHotKey()
    private let reader: SelectionReading
    private let pasteboard: PasteboardAccess
    private let environment: Environment
    /// 轮询延时调度（注入后测试可手动推进，不必等真实 20ms）
    private let scheduler: DelayScheduling
    /// 单调时钟（判断轮询截止）
    private let now: () -> Date

    /// 回调参数：选中文本、弹窗锚点（AX 路径为选区左上角，⌘C 兜底为鼠标位置）、选区前后文（⌘C 路径为 nil）
    private let onSelected: (String, NSPoint, String?) -> Void
    /// 抓取失败回调（可为空实现），弹窗据分类给出可操作提示
    private let onFailure: (SelectionFailure, NSPoint) -> Void

    /// 当前生效绑定：注册失败时的回滚基准，也是状态页展示的数据源
    private(set) var currentBinding: HotKeyBinding = CarbonKeyTranslator.defaultBinding

    /// 暂停取词（投屏/演示/输密码场景）：注销热键但保留绑定，恢复时原样注册回来
    private(set) var isPaused = false

    /// 事务互斥：AX 读取或剪贴板事务进行中时为 true。
    /// 剪贴板事务要一直持有到恢复完成——这是「连续两次查询污染剪贴板」的修复点。
    private(set) var isProcessing = false

    /// 取词代际：目标切换 / 暂停让旧结果作废（AX IPC 无法真正中断，只能丢弃结果）
    private var readToken = 0

    /// 轮询超时预算（复制响应慢的应用兜底上限）
    static let copyTimeout: TimeInterval = 0.5
    /// 轮询间隔
    static let pollInterval: TimeInterval = 0.02

    /// 热键当前是否注册成功（状态页展示用）
    var isHotKeyRegistered: Bool { hotKey.isRegistered }

    /// onSelected 必传；其余依赖缺省为生产实现
    init(
        onSelected: @escaping (String, NSPoint, String?) -> Void,
        onFailure: @escaping (SelectionFailure, NSPoint) -> Void = { _, _ in },
        reader: SelectionReading? = nil,
        pasteboard: PasteboardAccess? = nil,
        environment: Environment = .live,
        scheduler: DelayScheduling? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.onSelected = onSelected
        self.onFailure = onFailure
        // 默认实现延迟到 init 内构造：默认参数在非隔离上下文求值，无法创建主 actor 隔离实例
        self.reader = reader ?? AXSelectionReaderAdapter()
        self.pasteboard = pasteboard ?? ClipboardManager()
        self.environment = environment
        self.scheduler = scheduler ?? MainQueueDelayScheduler()
        self.now = now
    }

    /// 启动监听：按持久化配置注册热键（默认 ⌥⌘K）
    func start() {
        // 绑定来自配置（默认 ⌥⌘K，⌥⌘D 与系统「显示/隐藏 Dock」冲突）
        reloadHotKey(with: AppConfig.shared.hotKeyBinding)
    }

    /// 试注册新绑定：成功则更新 currentBinding；失败自动恢复原绑定并返回 false。
    /// 调用方（快捷键设置页）只有在返回 true 后才应持久化配置，保证任何时刻热键可用。
    @discardableResult
    func reloadHotKey(with binding: HotKeyBinding) -> Bool {
        if register(binding) {
            currentBinding = binding
            // 暂停期间改键：试注册验证冲突后立即注销，保持暂停语义
            if isPaused { hotKey.unregister() }
            Log.selection.info("快捷键 \(binding.displayString) 已注册：选中文字后按下即可抓取")
            return true
        }
        Log.selection.warning("快捷键 \(binding.displayString) 注册失败，回滚原绑定 \(self.currentBinding.displayString)")
        // 回滚原绑定；若原绑定也注册不上（极端场景）则保持未注册，状态页会显示红点
        _ = register(currentBinding)
        if isPaused { hotKey.unregister() }
        return false
    }

    /// 注册内部包装（reloadHotKey 与恢复暂停共用）
    private func register(_ binding: HotKeyBinding) -> Bool {
        hotKey.register(
            keyCode: binding.keyCode,
            modifiers: binding.carbonModifiers
        ) { [weak self] in
            self?.handleHotKey()
        }
    }

    /// 暂停/恢复取词：暂停时注销热键（状态页显示「已暂停」而非注册失败），恢复时按当前绑定重新注册
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused {
            // 暂停即作废在途取词：恢复后不该突然弹出暂停前的结果
            invalidateInFlight()
            hotKey.unregister()
            Log.selection.info("取词已暂停")
        } else {
            _ = register(currentBinding)
            Log.selection.info("取词已恢复")
        }
    }

    /// 热键回调入口（Carbon 回调不可 async）：把实际流程扔进主 actor 任务
    private func handleHotKey() {
        Task { [weak self] in
            await self?.performSelection()
        }
    }

    /// 一次完整取词：前置检查 → 异步 AX 直读 →（必要时）⌘C 兜底事务。
    /// 独立成 async 方法是为了让测试能确定性地 await 整条链路，而不是靠 sleep 猜时机。
    func performSelection() async {
        guard !isProcessing else {
            // 上一次取词（含剪贴板恢复窗口）还没结束：直接丢弃，绝不让两个事务交叉
            Log.selection.debug("上一次取词尚未结束，本次按键已丢弃")
            return
        }
        let mouse = environment.mouseLocation()
        // 前置检查：无权限/处于密码框/黑名单应用时抓取必然失败，与其让用户干等不如立刻说明
        guard let target = preflight(mouse: mouse) else { return }

        readToken += 1
        let token = readToken
        isProcessing = true

        let selection = await reader.read()
        // 目标切换或暂停导致代际变化：AX IPC 无法真正中断，只能丢弃这次结果
        guard token == readToken else {
            finish()
            return
        }
        if let selection, !selection.text.isEmpty {
            let anchor = selection.rect.map { NSPoint(x: $0.minX, y: $0.maxY) } ?? mouse
            Log.selection.debug("AX 直读成功：\(selection.text.count) 字符")
            finish()
            onSelected(selection.text, anchor, selection.context)
            return
        }
        // 兜底前重新确认目标应用与隐私条件：AX 可能刚等了 400ms，期间用户完全可能切走
        // 或点了密码框，此时模拟 ⌘C 会复制到错误的地方
        guard revalidate(target: target, mouse: mouse) else {
            finish()
            return
        }
        beginClipboardTransaction(mouse: mouse, token: token)
    }

    /// 前置检查：返回本次取词目标；不满足条件时直接回调失败并返回 nil
    private func preflight(mouse: NSPoint) -> Target? {
        guard environment.isAccessibilityTrusted() else {
            Log.selection.warning("未授予辅助功能权限，跳过抓取")
            onFailure(.noAccessibilityPermission, mouse)
            return nil
        }
        // 安全输入态（密码框聚焦等）：不抓取、不复制，保护隐私
        if environment.isSecureInputEnabled() {
            Log.selection.info("系统处于安全输入态，跳过抓取")
            onFailure(.secureInputActive, mouse)
            return nil
        }
        let bundleID = environment.frontmostBundleID()
        // 应用黑名单：密码/密钥管理类应用永不抓取
        if let bundleID, environment.blacklistedBundleIDs().contains(bundleID) {
            Log.selection.info("前台应用 \(bundleID) 在黑名单中，跳过抓取")
            onFailure(.blacklistedApp, mouse)
            return nil
        }
        return Target(pid: environment.frontmostPID(), bundleID: bundleID)
    }

    /// 兜底前复核：目标应用未变、仍非安全输入、仍非黑名单
    private func revalidate(target: Target, mouse: NSPoint) -> Bool {
        if environment.isSecureInputEnabled() {
            Log.selection.info("等待 AX 期间进入安全输入态，取消复制兜底")
            onFailure(.secureInputActive, mouse)
            return false
        }
        let bundleID = environment.frontmostBundleID()
        if let bundleID, environment.blacklistedBundleIDs().contains(bundleID) {
            Log.selection.info("等待 AX 期间前台应用切到黑名单应用 \(bundleID)，取消复制兜底")
            onFailure(.blacklistedApp, mouse)
            return false
        }
        if let pid = target.pid, environment.frontmostPID() != pid {
            Log.selection.info("等待 AX 期间前台应用已切换，取消复制兜底（避免复制到别处的内容）")
            onFailure(.targetChanged, mouse)
            return false
        }
        return true
    }

    /// 剪贴板兜底事务开始：快照 → 模拟 ⌘C → 轮询
    private func beginClipboardTransaction(mouse: NSPoint, token: Int) {
        let initialCount = pasteboard.saveSnapshot()
        environment.simulateCopy()
        pollRead(
            initialCount: initialCount,
            deadline: now().addingTimeInterval(Self.copyTimeout),
            mouse: mouse,
            token: token
        )
    }

    /// 轮询等待复制生效（20ms 间隔，0.5s 截止）：changeCount 变化即读取并条件恢复
    private func pollRead(initialCount: Int, deadline: Date, mouse: NSPoint, token: Int) {
        // 事务中途被暂停/新一轮取词取代：仍要把快照恢复回去，但不得再交付结果
        guard token == readToken else {
            Log.selection.debug("取词事务已被取代，恢复剪贴板快照后放弃本次结果")
            pasteboard.restoreSnapshot(readChangeCount: pasteboard.changeCount) { [weak self] _ in
                self?.finish()
            }
            return
        }
        if pasteboard.changeCount != initialCount {
            let text = pasteboard.readText()?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let readCount = pasteboard.changeCount
            // 恢复完成（或确认不恢复）后才释放互斥：此前 finish() 在这里就放锁，
            // 第二次查询能赶在恢复前保存快照，把本次复制的词条当成「用户原始剪贴板」
            guard !text.isEmpty else {
                Log.selection.debug("未抓取到文本（空选择）")
                pasteboard.restoreSnapshot(readChangeCount: readCount) { [weak self] _ in
                    self?.finish()
                }
                onFailure(.emptySelection, mouse)
                return
            }
            pasteboard.restoreSnapshot(readChangeCount: readCount) { [weak self] _ in
                self?.finish()
            }
            onSelected(text, mouse, nil) // ⌘C 兜底路径拿不到选区前后文
        } else if now() < deadline {
            scheduler.schedule(after: Self.pollInterval) { [weak self] in
                self?.pollRead(initialCount: initialCount, deadline: deadline, mouse: mouse, token: token)
            }
        } else {
            pasteboard.restoreSnapshot(readChangeCount: pasteboard.changeCount) { [weak self] _ in
                self?.finish()
            }
            Log.selection.debug("未抓取到文本（超时，应用复制响应慢或禁止复制）")
            onFailure(.timeout, mouse)
        }
    }

    /// 结束一次抓取（释放事务互斥）：仅在 AX 结果作废、剪贴板恢复完成等终态调用
    private func finish() {
        isProcessing = false
    }

    /// 作废在途取词（暂停时用）：结果被子代际校验丢弃。
    /// 不在这里强行清互斥——在途流程自己会走 finish()，剪贴板事务则由恢复回调释放，
    /// 否则会出现「快照还没恢复就放锁」的另一个版本同类缺陷。
    private func invalidateInFlight() {
        readToken += 1
    }
}