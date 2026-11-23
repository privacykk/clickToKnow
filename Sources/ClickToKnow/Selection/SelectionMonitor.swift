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
}

/// 监听全局快捷键，抓取前台应用当前选中的文本。
/// 主路径：AX 直读（不碰剪贴板，顺带选区矩形与前后文）；
/// 兜底：保存剪贴板快照 → 模拟 ⌘C → 轮询 changeCount → 读剪贴板 → 条件恢复。
@MainActor
final class SelectionMonitor {
    private let hotKey = GlobalHotKey()
    private let clipboard = ClipboardManager()
    /// 回调参数：选中文本、弹窗锚点（AX 路径为选区左上角，⌘C 兜底为鼠标位置）、选区前后文（⌘C 路径为 nil）
    private let onSelected: (String, NSPoint, String?) -> Void
    /// 抓取失败回调（可为空实现），弹窗据分类给出可操作提示
    private let onFailure: (SelectionFailure, NSPoint) -> Void

    /// 当前生效绑定：注册失败时的回滚基准，也是状态页展示的数据源
    private(set) var currentBinding: HotKeyBinding = CarbonKeyTranslator.defaultBinding

    /// 暂停取词（投屏/演示/输密码场景）：注销热键但保留绑定，恢复时原样注册回来
    private(set) var isPaused = false

    /// 抓取进行中标志。防止快速连按：第二次 saveSnapshot 会把第一次刚复制的
    /// 选词当作"原始剪贴板"备份，导致恢复后用户剪贴板被污染成错误内容。
    private var isProcessing = false

    /// 热键当前是否注册成功（状态页展示用）
    var isHotKeyRegistered: Bool { hotKey.isRegistered }

    /// onSelected 必传；onFailure 缺省为空实现（不提示）
    init(
        onSelected: @escaping (String, NSPoint, String?) -> Void,
        onFailure: @escaping (SelectionFailure, NSPoint) -> Void = { _, _ in }
    ) {
        self.onSelected = onSelected
        self.onFailure = onFailure
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
            hotKey.unregister()
            Log.selection.info("取词已暂停")
        } else {
            _ = register(currentBinding)
            Log.selection.info("取词已恢复")
        }
    }

    /// 热键触发入口：前置检查（权限/安全输入/黑名单）→ AX 直读 → ⌘C 兜底
    private func handleHotKey() {
        guard !isProcessing else { return }
        let mouse = NSEvent.mouseLocation

        // 前置检查：无权限时抓取必然失败，与其让用户干等，不如立刻说明原因
        guard AXIsProcessTrusted() else {
            Log.selection.warning("未授予辅助功能权限，跳过抓取")
            onFailure(.noAccessibilityPermission, mouse)
            return
        }
        // 安全输入态（密码框聚焦等）：不抓取、不复制，保护隐私
        if IsSecureEventInputEnabled() {
            Log.selection.info("系统处于安全输入态，跳过抓取")
            onFailure(.secureInputActive, mouse)
            return
        }
        // 应用黑名单：密码/密钥管理类应用永不抓取
        if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           AppConfig.shared.blacklistedBundleIDs.contains(bundleID) {
            Log.selection.info("前台应用 \(bundleID) 在黑名单中，跳过抓取")
            onFailure(.blacklistedApp, mouse)
            return
        }

        // 主路径：AX 直读。典型 <20ms；最坏情况（目标应用 IPC 挂起）主线程阻塞 0.4s 超时上限
        if let selection = AXSelectionReader.read() {
            let anchor = selection.rect.map { NSPoint(x: $0.minX, y: $0.maxY) } ?? mouse
            Log.selection.debug("AX 直读成功：\(selection.text.count) 字符")
            onSelected(selection.text, anchor, selection.context)
            return
        }

        // 兜底：模拟 ⌘C（目标应用未实现 AX 时）
        isProcessing = true
        let initialCount = clipboard.saveSnapshot()
        simulateCopy()
        pollRead(initialCount: initialCount, deadline: Date().addingTimeInterval(0.5), mouse: mouse)
    }

    /// 轮询等待复制生效（20ms 间隔，0.5s 截止）：changeCount 变化即读取并条件恢复快照
    private func pollRead(initialCount: Int, deadline: Date, mouse: NSPoint) {
        if clipboard.changeCount != initialCount {
            let text = clipboard.readText()?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let readCount = clipboard.changeCount
            clipboard.restoreSnapshot(readChangeCount: readCount)
            finish()
            guard !text.isEmpty else {
                Log.selection.debug("未抓取到文本（空选择）")
                onFailure(.emptySelection, mouse)
                return
            }
            onSelected(text, mouse, nil) // ⌘C 兜底路径拿不到选区前后文
        } else if Date() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                self?.pollRead(initialCount: initialCount, deadline: deadline, mouse: mouse)
            }
        } else {
            clipboard.restoreSnapshot(readChangeCount: clipboard.changeCount)
            finish()
            Log.selection.debug("未抓取到文本（超时，应用复制响应慢或禁止复制）")
            onFailure(.timeout, mouse)
        }
    }

    /// 结束一次抓取（解除 isProcessing 互斥）
    private func finish() {
        isProcessing = false
    }

    /// 向前台应用发送 ⌘C（需辅助功能权限，否则静默失败）。
    private func simulateCopy() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
    }
}
